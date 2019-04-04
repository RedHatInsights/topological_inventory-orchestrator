require "json"
require "manageiq-loggers"
require "manageiq-password"
require "rest-client"
require "yaml"

require "topological_inventory/orchestrator/object_manager"

module TopologicalInventory
  module Orchestrator
    class Worker
      API_VERSION = "v0.1".freeze

      attr_reader :logger

      def initialize(collector_definitions_file = ENV["COLLECTOR_DEFINITIONS_FILE"])
        @collector_definitions_file = collector_definitions_file || TopologicalInventory::Orchestrator.root.join("config/collector_definitions.yaml")
        @logger = ManageIQ::Loggers::Container.new
      end

      def run
        loop do
          make_openshift_match_database

          sleep 10
        end
      end

      private

      def api_base_url
        @api_base_url ||= begin
          path = File.join("/", ENV["PATH_PREFIX"].to_s, ENV["APP_NAME"].to_s, API_VERSION)

          require "uri"

          URI::HTTP.build(
            :host => ENV["TOPOLOGICAL_INVENTORY_API_SERVICE_HOST"],
            :port => ENV["TOPOLOGICAL_INVENTORY_API_SERVICE_PORT"],
            :path => path
          ).to_s
        end
      end

      def digest(object)
        require 'digest'
        Digest::SHA1.hexdigest(Marshal.dump(object))
      end

      def make_openshift_match_database
        hash = {}
        expected = collectors_from_sources_api(hash)
        current  = collectors_from_openshift

        logger.info("Checking...")

        (current - expected).each { |i| remove_openshift_objects_for_source(i) }
        (expected - current).each { |i| create_openshift_objects_for_source(i, hash[i]) }

        logger.info("Checking... complete.")
      end


      ### API STUFF
      def each_source
        return enum_for(:each_source) unless block_given?
        each_resource(url_for("source_types")) do |source_type|
          collector_definition = collector_definitions[source_type["name"]]
          next if collector_definition.nil?
          each_resource(url_for("source_types/#{source_type["id"]}/sources")) do |source|
            next unless endpoint = get_and_parse(url_for("sources/#{source["id"]}/endpoints"))["data"].first
            next unless authentication = get_and_parse(url_for("authentications?resource_type=Endpoint&resource_id=#{endpoint["id"]}"))["data"].first
            yield source, endpoint, authentication, collector_definition
          end
        end
      end

      def collectors_from_sources_api(hash)
        each_source.collect do |source, endpoint, authentication, collector_definition|
          auth = authentication_with_password(authentication["id"])
          value = {
            "endpoint_host"   => endpoint["host"],
            "endpoint_path"   => endpoint["path"],
            "endpoint_port"   => endpoint["port"].to_s,
            "endpoint_scheme" => endpoint["scheme"],
            "image"           => collector_definition["image"],
            "image_namespace" => collector_definition["image_namespace"] || ENV["IMAGE_NAMESPACE"],
            "source_id"       => source["id"],
            "source_uid"      => source["uid"],
            "secret"          => {
              "password" => auth["password"],
              "username" => auth["username"],
            },
          }
          key = digest(value)
          hash[key] = value
          key
        end
      end

      def url_for(path)
        File.join(api_base_url, path)
      end

      def each_resource(url, &block)
        return if url.nil?
        response = get_and_parse(url)
        response["data"].each { |i| yield i }
        each_resource(response["links"]["next"], &block)
      end

      def get_and_parse(url)
        JSON.parse(RestClient.get(url))
      end


      # HACK for Authentications
      def authentication_with_password(id)
        url = URI.parse(api_base_url).tap do |uri|
          uri.path = "/internal/v0.0/authentications/#{id}"
          uri.query = "expose_encrypted_attribute[]=password"
        end.to_s
        get_and_parse(url.to_s)
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
        logger.info("Creating objects for source #{source["source_id"]} with digest #{digest}")
        object_manager.create_secret(collector_deployment_secret_name_for_source(source), source["secret"])
        object_manager.create_deployment_config(collector_deployment_name_for_source(source), source["image_namespace"], source["image"]) do |d|
          d[:metadata][:labels]["topological-inventory/collector_digest"] = digest
          d[:metadata][:labels]["topological-inventory/collector"] = "true"
          d[:spec][:replicas] = 1
          container = d[:spec][:template][:spec][:containers].first
          container[:env] = collector_container_environment(source)
        end
      end

      def remove_openshift_objects_for_source(digest)
        return unless digest
        deployment = object_manager.get_deployment_configs("topological-inventory/collector_digest=#{digest}").detect { |i| i.metadata.labels["topological-inventory/collector"] == "true" }
        return unless deployment
        logger.info("Removing objects for deployment #{deployment.metadata.name}")
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
          {:name => "ENDPOINT_HOST", :value => source["endpoint_host"]},
          {:name => "ENDPOINT_PATH", :value => source["endpoint_path"]},
          {:name => "ENDPOINT_PORT", :value => source["endpoint_port"]},
          {:name => "ENDPOINT_SCHEME", :value => source["endpoint_scheme"]},
          {:name => "INGRESS_API", :value => "http://#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_HOST"]}:#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_PORT"]}"},
          {:name => "SOURCE_UID",  :value => source["source_uid"]},
        ]
      end
    end
  end
end
