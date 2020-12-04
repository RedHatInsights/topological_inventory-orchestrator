require "kubeclient"
require "more_core_extensions/core_ext/string/iec60027_2"

module TopologicalInventory
  module Orchestrator
    class ObjectManager
      include Logging
      TOKEN_FILE   = "/run/secrets/kubernetes.io/serviceaccount/token".freeze
      CA_CERT_FILE = "/run/secrets/kubernetes.io/serviceaccount/ca.crt".freeze

      attr_accessor :metrics

      class QuotaError < RuntimeError; end
      class QuotaCpuLimitExceeded < QuotaError; end
      class QuotaCpuRequestExceeded < QuotaError; end
      class QuotaMemoryLimitExceeded < QuotaError; end
      class QuotaMemoryRequestExceeded < QuotaError; end

      def self.available?
        File.exist?(TOKEN_FILE) && File.exist?(CA_CERT_FILE)
      end

      def initialize(metrics)
        self.metrics = metrics
      end

      def scale(deployment_config_name, replicas)
        connection.patch_deployment_config(deployment_config_name, { :spec => { :replicas => replicas } }, my_namespace)
      end

      def get_pods
        kube_connection.get_pods(:namespace => my_namespace)
      end

      def delete_pod(name)
        kube_connection.delete_pod(name, my_namespace)
      end

      def get_deployment_config(name)
        connection.get_deployment_config(name, my_namespace)
      rescue KubeException
        logger.warn("[WARN] Deployment Config not found: #{name}")
        nil
      end

      def get_deployment_configs(label_selector)
        connection.get_deployment_configs(
          :label_selector => label_selector,
          :namespace      => my_namespace
        )
      end

      def create_deployment_config(name, type, source_type = 'unknown')
        definition = deployment_config_definition(name, type)
        yield(definition) if block_given?
        check_deployment_config_quota(definition)
        connection.create_deployment_config(definition)

        metrics&.record_deployment_configs(:add, :source_type => source_type)
      rescue KubeException => e
        raise unless e.message =~ /already exists/
        logger.warn("[WARN] Deployment Config already exists: #{name}")
      end

      def update_deployment_config(deployment_config_name, patch)
        connection.patch_deployment_config(deployment_config_name, patch, my_namespace)
      end

      def delete_deployment_config(name, source_type = 'unknown')
        rc = kube_connection.get_replication_controllers(
          :label_selector => "openshift.io/deployment-config.name=#{name}",
          :namespace      => my_namespace
        ).first

        scale(name, 0)
        delete_options = Kubeclient::Resource.new(
          :apiVersion         => 'v1',
          :gracePeriodSeconds => 0,
          :kind               => 'DeleteOptions',
          :propagationPolicy  => 'Background' # Orphan, Foreground, or Background
        )
        connection.delete_deployment_config(name, my_namespace, :delete_options => delete_options)
        delete_replication_controller(rc.metadata.name) if rc

        metrics&.record_deployment_configs(:remove, :source_type => source_type)
      rescue Kubeclient::ResourceNotFoundError
        logger.warn("[WARN] Deployment Config does not exist: #{name}")
      end

      def get_secrets(label_selector)
        kube_connection.get_secrets(
          :label_selector => label_selector,
          :namespace      => my_namespace
        )
      end

      def create_secret(name, data, source_type = 'unknown')
        definition = secret_definition(name, data)
        yield(definition) if block_given?
        kube_connection.create_secret(definition)

        metrics&.record_secrets(:add, :source_type => source_type)
      rescue KubeException => e
        raise unless e.message =~ /already exists/
        logger.warn("[WARN] Secret already exists: #{name}")
      end

      def update_secret(secret)
        kube_connection.update_secret(secret)
      end

      def delete_secret(name, source_type = 'unknown')
        kube_connection.delete_secret(name, my_namespace)

        metrics&.record_secrets(:remove, :source_type => source_type)
      rescue Kubeclient::ResourceNotFoundError
        logger.warn("[WARN] Secret not found: #{name}")
      end

      def create_config_map(name, source_type = 'unknown')
        definition = config_map_definition(name)
        yield(definition) if block_given?
        kube_connection.create_config_map(definition)

        metrics&.record_config_maps(:add, :source_type => source_type)
      rescue KubeException => e
        raise unless e.message =~ /already exists/
        logger.warn("[WARN] ConfigMap already exists: #{name}")
      end

      def get_config_maps(label_selector)
        kube_connection.get_config_maps(
          :label_selector => label_selector,
          :namespace      => my_namespace
        )
      end

      def update_config_map(map)
        kube_connection.update_config_map(map)
      end

      def delete_config_map(name, source_type = 'unknown')
        kube_connection.delete_config_map(name, my_namespace)
        metrics&.record_config_maps(:remove, :source_type => source_type)
      end

      def create_service(name, source_type = 'unknown')
        definition = service_definition(name)
        yield(definition) if block_given?
        kube_connection.create_service(definition)

        metrics&.record_services(:add, :source_type => source_type)
      rescue KubeException => e
        raise unless e.message =~ /already exists/
        logger.warn("[WARN] Service already exists: #{name}")
      end

      def get_services(label_selector)
        kube_connection.get_services(
          :label_selector => label_selector,
          :namespace      => my_namespace
        )
      end

      def update_service(service)
        kube_connection.update_service(service)
      end

      def delete_service(name, source_type = 'unknown')
        kube_connection.delete_service(name, my_namespace)
        metrics&.record_services(:remove, :source_type => source_type)
      end

      def get_endpoint(name)
        kube_connection.get_endpoint(name, my_namespace)
      end

      def delete_replication_controller(name)
        kube_connection.delete_replication_controller(name, my_namespace)
      rescue Kubeclient::ResourceNotFoundError
        logger.warn("[WARN] ReplicationController not found: #{name}")
      end

      def get_collector_image(name)
        pod = kube_connection.get_pods(
          :namespace      => my_namespace,
          :label_selector => "name=topological-inventory-#{name}-operations"
        ).first

        pod&.spec&.containers&.first&.image
      end

      def collector_resources
        {
          :limits   => {
            :cpu    => ENV["COLLECTOR_LIMIT_CPU"] || "100m",
            :memory => ENV["COLLECTOR_LIMIT_MEM"] || "500Mi"
          },
          :requests => {
            :cpu    => ENV["COLLECTOR_REQUEST_CPU"] || "50m",
            :memory => ENV["COLLECTOR_REQUEST_MEM"] || "200Mi"
          }
        }
      end

      private

      def connection
        @connection ||= detect_openshift_connection
      end

      def kube_connection
        @kube_connection ||= raw_connect(manager_uri("/api"))
      end

      def raw_connect(uri, version = "v1")
        ssl_options = {
          :verify_ssl => OpenSSL::SSL::VERIFY_PEER,
          :ca_file    => CA_CERT_FILE
        }

        Kubeclient::Client.new(
          uri,
          version,
          :auth_options => { :bearer_token_file => TOKEN_FILE },
          :ssl_options  => ssl_options
        )
      end

      def manager_uri(path)
        URI::HTTPS.build(
          :host => ENV["KUBERNETES_SERVICE_HOST"],
          :port => ENV["KUBERNETES_SERVICE_PORT"],
          :path => path
        )
      end

      def detect_openshift_connection
        v3_connection = raw_connect(manager_uri("/oapi"))
        return v3_connection if client_connection_valid?(v3_connection)

        v4_connection = raw_connect(manager_uri("/apis/apps.openshift.io"))
        return v4_connection if client_connection_valid?(v4_connection)

        raise "Failed to detect a valid OpenShift connection"
      end

      def client_connection_valid?(conn)
        conn.discover
        true
      rescue Kubeclient::ResourceNotFoundError
        false
      end

      def quota_defined?
        @quota_defined ||= begin
          !!non_terminating_resource_quota
        rescue Kubeclient::ResourceNotFoundError
          false
        end
      end

      def non_terminating_resource_quota
        kube_connection.get_resource_quota("compute-resources-non-terminating", my_namespace)
      end

      def check_deployment_config_quota(definition)
        return unless quota_defined?

        quota_status = non_terminating_resource_quota.status

        cpu_limit = cpu_string_to_millicores(quota_status.used["limits.cpu"])
        definition.dig(:spec, :template, :spec, :containers).each do |container|
          cpu_limit += cpu_string_to_millicores(container.dig(:resources, :limits, :cpu))
        end
        raise(QuotaCpuLimitExceeded) if cpu_limit >= cpu_string_to_millicores(quota_status.hard["limits.cpu"])

        cpu_request = cpu_string_to_millicores(quota_status.used["requests.cpu"])
        definition.dig(:spec, :template, :spec, :containers).each do |container|
          cpu_request += cpu_string_to_millicores(container.dig(:resources, :requests, :cpu))
        end
        raise(QuotaCpuRequestExceeded) if cpu_request >= cpu_string_to_millicores(quota_status.hard["requests.cpu"])

        memory_limit = quota_status.used["limits.memory"].iec_60027_2_to_i
        definition.dig(:spec, :template, :spec, :containers).each do |container|
          memory_limit += container.dig(:resources, :limits, :memory).iec_60027_2_to_i
        end
        raise(QuotaMemoryLimitExceeded) if memory_limit >= quota_status.hard["limits.memory"].iec_60027_2_to_i

        memory_request = quota_status.used["requests.memory"].iec_60027_2_to_i
        definition.dig(:spec, :template, :spec, :containers).each do |container|
          memory_request += container.dig(:resources, :requests, :memory).iec_60027_2_to_i
        end
        raise(QuotaMemoryRequestExceeded) if memory_request >= quota_status.hard["requests.memory"].iec_60027_2_to_i

      rescue Kubeclient::ResourceNotFoundError
      end

      def cpu_string_to_millicores(input)
        match = input.match(/(?<number>\d+)(?<suffix>m?)/)
        match[:suffix].empty? ? (match[:number].to_i * 1000) : match[:number].to_i
      end

      def config_map_definition(name)
        {
          :metadata => {
            :name      => name,
            :labels    => {:app => app_name},
            :namespace => my_namespace,
          },
          :data     => {}
        }
      end

      def deployment_config_definition(name, image)
        deploy = {
          :metadata => {
            :name      => name,
            :labels    => {:app => app_name},
            :namespace => my_namespace,
          },
          :spec     => {
            :selector => {:name => name},
            :template => {
              :metadata => {
                :annotations => {
                  "prometheus.io/path"   => "/metrics",
                  "prometheus.io/port"   => "9394",
                  "prometheus.io/scrape" => "true",
                },
                :labels      => {
                  :app  => app_name,
                  :name => name,
                },
                :name        => name
              },
              :spec     => {
                :containers => [{
                  :name      => name,
                  :image     => image,
                  :resources => collector_resources
                }],
                :volumes    => []
              }
            }
          }
        }

        deploy.tap do |obj|
          if image.include?("quay.io")
            obj.dig(:spec, :template, :spec)[:imagePullSecrets] = [{:name => "quay-cloudservices-pull"}]
          end
        end
      end

      def secret_definition(name, string_data)
        {
          :metadata   => {
            :name      => name,
            :labels    => {:app => app_name},
            :namespace => my_namespace
          },
          :stringData => string_data
        }
      end

      def service_definition(name)
        {
          :metadata => {
            :name => name,
            :labels => {:app => app_name},
            :namespace => my_namespace
          },
          :spec => {
            :ports => [{
              :name => '9394',
              :port => 9394,
              :targetPort => 9394
            }],
            :selector => {
              :name => name.sub('service', 'collector')
            }
          }
        }
      end

      def my_namespace
        ENV["MY_NAMESPACE"]
      end

      def app_name
        "topological-inventory"
      end
    end
  end
end
