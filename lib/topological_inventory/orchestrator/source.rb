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

      def initialize(attributes, tenant, source_type, from_sources_api: nil)
        super(attributes)

        self.tenant = tenant
        self.source_type = source_type
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

        config_map
      end

      def update_in_openshift
        config_map&.update_source(self)
        config_map
      end

      def remove_from_openshift
        config_map&.remove_source(self)
        map = config_map
        self.config_map = nil
        map
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

      def digest(reload: false)
        return @digest if @digest.present? && !reload
        return nil if attributes.nil? || endpoint.nil?

        # If we are not going through a receptor node
        return nil if endpoint["receptor_node"].blank? && (authentication.nil? || credentials.nil?)

        @digest = compute_digest(digest_values)
      end

      def azure_tenant
        authentication.try(:[], "extra").try(:[], "azure").try(:[], "tenant_id")
      end

      private

      def digest_values
        hash = {
          "endpoint_host"   => endpoint["host"],
          "endpoint_path"   => endpoint["path"],
          "endpoint_port"   => endpoint["port"].to_s,
          "endpoint_scheme" => endpoint["scheme"],
          "image"           => source_type["collector_image"],
          "source_id"       => attributes["id"],
          "source_uid"      => attributes["uid"],
          "secret"          => {
            "password" => credentials.try(:[], "password"),
            "username" => credentials.try(:[], "username"),
          }
        }
        # Azure has extra parameter "tenant_id"
        if source_type.azure?
          tenant_id = azure_tenant.to_s
          hash['secret']['tenant_id'] = tenant_id if tenant_id.present?
        end

        # Set the receptor fields if they are present.
        if endpoint["receptor_node"].present?
          hash["receptor_node"] = endpoint["receptor_node"]
          hash["account_number"] = tenant
        end
        hash
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
