require "json"
require "yaml"
require "rest-client"
require "pg"
require "miq-password"

require "topological_inventory/orchestrator/object_manager"

module TopologicalInventory
  module Orchestrator
    class Worker
      attr_reader :api_url, :ingress_url

      def initialize(api_url, ingress_url, collector_definitions_file)
        raise "Access to the cluster using serviceaccounts is required" unless ObjectManager.available?
        @api_url               = api_url
        @ingress_url           = ingress_url
        @object_manager        = ObjectManager.new
        @collector_definitions = YAML.load_file(collector_definitions_file)
      end

      def run
        loop do
          Signal.trap("TERM") { break }
          collector_definitions.each do |source_type, endpoint_info|
            endpoint_info.each do |endpoint_role, options|
              resolve_collector_type(source_type, endpoint_role, options)
            end
          end
          sleep 10
        end
      end

      def resolve_collector_type(source_type, endpoint_role, options)
      end

      def create_collectors_for_new_sources
        sources.each do |source|
          create_objects_for_source(source) unless have_deployment_for_source?(source)
        end
      end
      
      def remove_collectors_for_deleted_sources
        collector_deployments.each do |deployment|
          unless sources.include?(source_for_deployment(deployment))
            @object_manager.delete_deployment_config(deployment.metadata.name)
            @object_manager.delete_secret("#{deployment.metadata.name}-secrets")
          end
        end
      end

      def have_deployment_for_source?(source)
        collector_deployments.detect do |deployment|
          source_for_deployment(deployment) == source["uid"]
        end
      end

      def create_objects_for_source(source)
        @object_manager.create_deployment_config(deployment_name_for_source(source)) do |d|
          container = d[:spec][:template][:spec][:containers].first
          container[:env] << collector_container_environment(source)
          container[:image] = "#{ENV["MY_NAMESPACE"]}/topological-inventory-collector-openshift:latest"
        end
      end

      private

      def collector_container_environment(source)
      end

      def secret_name_for_source(source)
        "#{deployment_name_for_source(source)}-secrets"
      end

      def deployment_name_for_source(source)
        "topological-inventory-collector-source-#{source["id"]}"
      end

      def source_for_deployment(d)
        d.metadata.labels["topological-inventory/source"]
      end

      def sources
        @sources ||= JSON.parse(RestClient.get(File.join(api_url, "api/v0.0/sources")))
      end

      def collector_deployments
        @collector_deployments ||= @object_manager.get_deployment_configs("topological-inventory/collector=true")
      end

      def endpoints_for_source(source_id)
        JSON.parse(RestClient.get(File.join(api_url, "api/v0.0/sources/#{source_id}/endpoints")))
      end

      def authentication_for_endpoint(endpoint_id)
        conn = PG::Connection.new(pg_connection_args)
        sql = <<~SQL
          SELECT *
          FROM authentications
          WHERE
            resource_type = 'Endpoint' AND
            resource_id = $1
        SQL
        conn.exec_params(sql, [endpoint_id]).first.tap do |auth|
          auth["password"] = MiqPassword.decrypt(auth["password"])
        end
      end

      def pg_connection_args
        {
          :host     => ENV["DATABASE_HOST"],
          :port     => ENV["DATABASE_PORT"],
          :dbname   => ENV["DATABASE_NAME"],
          :user     => ENV["DATABASE_USER"],
          :password => ENV["DATABASE_PASSWORD"]
        }.freeze
      end

      def clear_caches
        @sources = nil
        @collector_deployments = nil
      end
    end
  end
end
