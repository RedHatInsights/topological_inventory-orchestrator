require 'digest'
require "topological_inventory/orchestrator/api_object"

module TopologicalInventory
  module Orchestrator
    class Source < ApiObject
      attr_accessor :config_map, :source_type, :from_sources_api, :tenant
      attr_accessor :collector_definition,
                    :endpoint, :authentication, :credentials

      def to_s
        name = ''
        name = attributes['uid'].to_s if attributes.present?
        name += " (ConfigMap: #{config_map})" if config_map.present?
        name
      end

      def initialize(attributes, tenant, source_type, collector_definition, from_sources_api:)
        super(attributes)

        self.tenant = tenant
        self.source_type = source_type
        self.collector_definition = collector_definition
        self.from_sources_api = from_sources_api

        self.endpoint = nil
        self.authentication = nil
        self.credentials = nil

        self.config_map = nil
      end

      def add_to_openshift(object_manager, config_maps)
        add_to_existing_collector(config_maps)

        if config_map.nil?
          deploy_new_collector(object_manager)
        end
      end

      def remove_from_openshift
        config_map&.remove_source(self)
      end

      def load_credentials(api)
        self.endpoint = api.get_endpoint(attributes['id'], tenant)
        return if endpoint.nil?

        self.authentication = api.get_authentication(endpoint['id'], tenant)
        return if authentication.nil?

        self.credentials = api.get_credentials(authentication['id'], tenant)
      end

      def digest=(value)
        @digest = value
      end

      def digest
        return @digest if @digest.present?
        return nil if attributes.nil? || endpoint.nil? || authentication.nil? || credentials.nil?

        @digest = compute_digest(digest_values)
      end

      private

      def digest_values
        {
          "endpoint_host"   => endpoint["host"],
          "endpoint_path"   => endpoint["path"],
          "endpoint_port"   => endpoint["port"].to_s,
          "endpoint_scheme" => endpoint["scheme"],
          "image"           => collector_definition["image"],
          "image_namespace" => ENV["IMAGE_NAMESPACE"],
          "source_id"       => attributes["id"],
          "source_uid"      => attributes["uid"],
          "secret"          => {
            "password" => credentials["password"],
            "username" => credentials["username"],
          }
        }
      end

      def compute_digest(object)
        Digest::SHA1.hexdigest(Marshal.dump(object))
      end

      def name
        "tp-inventory-collector-#{config_map.uid}"
      end

      # @return [ConfigMap | nil]
      def deploy_new_collector(object_manager)
        ConfigMap.deploy_new(object_manager, self)
      end

      # Adds source's creds to config map
      def add_to_existing_collector(config_maps)
        config_maps.each do |map|
          next unless map.available?(self)

          map.add_source(self)
          self.config_map = map
          break
        end
      end
    end
  end
end
