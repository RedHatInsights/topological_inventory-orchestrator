require "json"
require "miq-password"
require "pg"
require "rest-client"
require "yaml"

require "topological_inventory/orchestrator/object_database"
require "topological_inventory/orchestrator/object_manager"

module TopologicalInventory
  module Orchestrator
    class Worker
      def initialize(api_base_url: ENV["API_URL"], collector_definitions_file: ENV["CONTAINER_DEFINITIONS_FILE"])
        @api_base_url = api_base_url
        @collector_definitions_file = collector_definitions_file || "/opt/topological_inventory-orchestrator/config/collector_definitions.yaml"
      end

      def run
        loop do
          make_openshift_match_database

          sleep 10
        end
      end

      private

      def make_openshift_match_database
        database = ObjectDatabase.new
        expected = collectors_from_database(database)
        current  = collectors_from_openshift

        puts "Checking..."

        (current - expected).each { |i| remove_openshift_objects_for_source(i) }
        (expected - current).each { |i| create_openshift_objects_for_source(i, database[i]) }

        puts "Checking... complete."
      end


      ### API STUFF
      def collectors_from_database(database)
        [].tap do |array|
          api_get("source_types").each do |source_type|
            collector_definition = collector_definitions[source_type["name"]]
            next if collector_definition.nil?
            api_get("source_types/#{source_type["id"]}/sources").each do |source|
              api_get("sources/#{source["id"]}/endpoints").each do |endpoint|
                definition_information = collector_definition[endpoint["role"]]
                next unless definition_information
                auth = authentication_for_endpoint(endpoint["id"].to_i)
                array << database.add(
                  {
                    "host"       => endpoint["host"],
                    "image"      => definition_information["image"],
                    "source_id"  => source["id"],
                    "source_uid" => source["uid"],
                    "secret"     => {
                      "password" => auth["password"],
                      "username" => auth["username"],
                    },
                  }
                )
              end
            end
          end
        end
      end

      def api_get(path)
        JSON.parse(RestClient.get(File.join(@api_base_url, path)))
      end


      # HACK for Authentications
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
          next if auth.nil?
          auth["password"] = MiqPassword.decrypt(auth["password"])
        end || {}
      end

      def pg_connection_args
        @pg_connection_args ||= {
          :host     => ENV["DATABASE_HOST"],
          :port     => ENV["DATABASE_PORT"],
          :dbname   => ENV["DATABASE_NAME"],
          :user     => ENV["DATABASE_USER"],
          :password => ENV["DATABASE_PASSWORD"]
        }.freeze
      end


      ### Orchestrator Stuff
      def collector_definitions
        @collector_definitions ||= begin
          require 'yaml'
          YAML.load_file(@collector_definitions_file)
        end
      end

      def object_manager
        @object_manager ||= ObjectManager.new
      end


      ### Openshift stuff
      def collectors_from_openshift
        object_manager.get_deployment_configs("topological-inventory/collector=true").collect { |i| i.metadata.labels["topological-inventory/collector_digest"] }
      end

      def create_openshift_objects_for_source(digest, source)
        puts "Creating objects for source #{source["source_id"]} with digest #{digest}"
        object_manager.create_secret(collector_deployment_secret_name_for_source(source), source["secret"])
        object_manager.create_deployment_config(collector_deployment_name_for_source(source)) do |d|
          d[:metadata][:labels]["topological-inventory/collector_digest"] = digest
          d[:metadata][:labels]["topological-inventory/collector"] = "true"
          d[:spec][:replicas] = 1
          container = d[:spec][:template][:spec][:containers].first
          container[:env] = collector_container_environment(source)
          container[:image] = source["image"]
        end
      end

      def remove_openshift_objects_for_source(digest)
        return unless digest
        deployment = object_manager.get_deployment_configs("topological-inventory/collector_digest=#{digest}").detect { |i| i.metadata.labels["topological-inventory/collector"] == "true" }
        return unless deployment
        puts "Removing objects for deployment #{deployment.metadata.name}"
        object_manager.delete_deployment_config(deployment.metadata.name)
        object_manager.delete_secret("#{deployment.metadata.name}-secrets")
      end

      def collector_deployment_name_for_source(source)
        "topological-inventory-collector-source-#{source["source_id"]}"
      end

      def collector_deployment_secret_name_for_source(source)
        "#{collector_deployment_name_for_source(source)}-secrets"
      end

      def collector_container_environment(source)
        secret_name = "#{collector_deployment_name_for_source(source)}-secrets"
        [
          {:name => "AUTH_PASSWORD", :valueFrom => {:secretKeyRef => {:name => secret_name, :key => "password"}}},
          {:name => "AUTH_USERNAME", :valueFrom => {:secretKeyRef => {:name => secret_name, :key => "username"}}},
          {:name => "INGRESS_API", :value => ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_PORT"].sub("tcp://", "http://")},
          {:name => "OPENSHIFT_HOSTNAME", :value => source["host"]},
          {:name => "SOURCE_UID",  :value => source["source_uid"]},
        ]
      end
    end
  end
end
