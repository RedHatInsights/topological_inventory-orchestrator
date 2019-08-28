require "kubeclient"
require "more_core_extensions/core_ext/string/iec60027_2"

module TopologicalInventory
  module Orchestrator
    class ObjectManager
      TOKEN_FILE   = "/run/secrets/kubernetes.io/serviceaccount/token".freeze
      CA_CERT_FILE = "/run/secrets/kubernetes.io/serviceaccount/ca.crt".freeze

      class QuotaError < RuntimeError; end
      class QuotaCpuLimitExceeded < QuotaError; end
      class QuotaCpuRequestExceeded < QuotaError; end
      class QuotaMemoryLimitExceeded < QuotaError; end
      class QuotaMemoryRequestExceeded < QuotaError; end

      def self.available?
        File.exist?(TOKEN_FILE) && File.exist?(CA_CERT_FILE)
      end

      def scale(deployment_config_name, replicas)
        connection.patch_deployment_config(deployment_config_name, { :spec => { :replicas => replicas } }, my_namespace)
      end

      def create_deployment_config(name, image_namespace, image)
        definition = deployment_config_definition(name, image_namespace, image)
        yield(definition) if block_given?
        check_deployment_config_quota(definition)
        connection.create_deployment_config(definition)
      rescue KubeException => e
        raise unless e.message =~ /already exists/
      end

      def create_secret(name, data)
        definition = secret_definition(name, data)
        yield(definition) if block_given?
        kube_connection.create_secret(definition)
      rescue KubeException => e
        raise unless e.message =~ /already exists/
      end

      def get_deployment_config(name)
        connection.get_deployment_config(name, my_namespace)
      end

      def get_deployment_configs(label_selector)
        connection.get_deployment_configs(
          :label_selector => label_selector,
          :namespace      => my_namespace
        )
      end

      def get_endpoint(name)
        kube_connection.get_endpoint(name, my_namespace)
      end

      def delete_deployment_config(name)
        rc = kube_connection.get_replication_controllers(
          :label_selector => "openshift.io/deployment-config.name=#{name}",
          :namespace      => my_namespace
        ).first

        scale(name, 0)
        delete_options = Kubeclient::Resource.new(
          :apiVersion         => 'meta/v1',
          :gracePeriodSeconds => 0,
          :kind               => 'DeleteOptions',
          :propagationPolicy  => 'Foreground' # Orphan, Foreground, or Background
        )
        connection.delete_deployment_config(name, my_namespace, :delete_options => delete_options)
        delete_replication_controller(rc.metadata.name) if rc
      rescue Kubeclient::ResourceNotFoundError
      end

      def delete_replication_controller(name)
        kube_connection.delete_replication_controller(name, my_namespace)
      rescue Kubeclient::ResourceNotFoundError
      end

      def delete_secret(name)
        kube_connection.delete_secret(name, my_namespace)
      rescue Kubeclient::ResourceNotFoundError
      end

      private

      def connection
        @connection ||= raw_connect(manager_uri("/oapi"))
      end

      def kube_connection
        @kube_connection ||= raw_connect(manager_uri("/api"))
      end

      def raw_connect(uri)
        ssl_options = {
          :verify_ssl => OpenSSL::SSL::VERIFY_PEER,
          :ca_file    => CA_CERT_FILE
        }

        Kubeclient::Client.new(
          uri,
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
      end

      def cpu_string_to_millicores(input)
        match = input.match(/(?<number>\d+)(?<suffix>m?)/)
        match[:suffix].empty? ? (match[:number].to_i * 1000) : match[:number].to_i
      end

      def deployment_config_definition(name, image_namespace, image)
        {
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
                  :image     => "#{image_namespace}/#{image}",
                  :resources => {
                    :limits   => {
                      :cpu    => "50m",
                      :memory => "400Mi"
                    },
                    :requests => {
                      :cpu    => "20m",
                      :memory => "200Mi"
                    }
                  }
                }]
              }
            },
            :triggers => [{
              :type              => "ImageChange",
              :imageChangeParams => {
                :automatic      => true,
                :containerNames => [name],
                :from           => {
                  :kind      => "ImageStreamTag",
                  :name      => image,
                  :namespace => image_namespace
                }
              }
            }]
          }
        }
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

      def my_namespace
        ENV["MY_NAMESPACE"]
      end

      def app_name
        "topological-inventory"
      end
    end
  end
end
