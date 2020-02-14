require "topological_inventory/orchestrator/openshift_object"

module TopologicalInventory
  module Orchestrator
    # Secret is maintained by config map
    # Paired by LABEL_UNIQUE label
    class Secret < OpenshiftObject
      LABEL_COMMON = "tp-inventory/collectors-secret".freeze
      LABEL_UNIQUE = "tp-inventory/config-uid".freeze

      attr_accessor :config_map

      def to_s
        uid
      end

      def create_in_openshift
        logger.info("Creating Secret #{self}")
        raise "Cannot create secret, no config map associated" if config_map.nil?

        object_manager.create_secret(name, data) do |secret|
          secret[:metadata][:labels][LABEL_UNIQUE] = uid
          secret[:metadata][:labels][LABEL_COMMON] = "true"
          secret[:metadata][:labels][ConfigMap::LABEL_SOURCE_TYPE] = config_map.source_type['name'] if config_map.source_type.present?
        end

        logger.info("[OK] Created Secret #{self}")
      end

      # Updating secret values for all sources attached to related configmap
      # Full update
      def update!
        logger.info("Updating Secret #{self}")

        if openshift_object.present?
          openshift_object.stringData = data
          object_manager.update_secret(openshift_object)

          logger.info("[OK] Updated Secret #{self}")
        else
          logger.warn("Updating Secret - not found: #{self}")
        end
      end

      # Update or insert
      # Targeted update
      def upsert_one!(source)
        logger.info("Updating Secret #{self}")

        if openshift_object.present?
          resource = openshift_object.data

          credentials = JSON.parse(Base64.decode64(resource.credentials))
          credentials[source['uid']] = source_to_data(source)
          credentials['updated_at'] = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")

          openshift_object.stringData = { "credentials" => credentials.to_json }
          object_manager.update_secret(openshift_object)

          logger.info("[OK] Updated Secret #{self}")
        else
          logger.warn("Updating Secret - not found: #{self}")
        end
      rescue JSON::ParserError => e
        logger.error("[ERROR] Updating secret #{self}: #{e.message}")
      end

      def targeted_delete(source)
        logger.info("Deleting #{source} from Secret #{self}")

        if openshift_object.present?
          resource = openshift_object.data

          credentials = JSON.parse(Base64.decode64(resource.credentials))

          credentials.delete(source['uid'])

          credentials['updated_at'] = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")

          openshift_object.stringData = { "credentials" => credentials.to_json }
          object_manager.update_secret(openshift_object)

          logger.info("[OK] Updated Secret #{self}")
        else
          logger.warn("Updating Secret - not found: #{self}")
        end
      rescue JSON::ParserError => e
        logger.error("[ERROR] Updating secret #{self}: #{e.message}")
      end

      def delete_in_openshift
        logger.info("Deleting Secret #{self}")

        object_manager.delete_secret(name)

        logger.info("[OK] Deleted Secret #{self}")
      end

      def name
        source_type = config_map&.source_type
        type_name   = source_type.present? ? source_type['name'] : 'unknown'
        "secret-#{type_name}-#{uid}"
      end

      # Secret config-UID is relation to config-map's template
      def uid
        return @uid if @uid.present?

        @uid = if @openshift_object.present? # no openshift_object reloading here (cycle)
                 @openshift_object.metadata.labels[LABEL_UNIQUE]
               else
                 config_map&.uid
               end
      end

      private

      def load_openshift_object
        object_manager.get_secrets(LABEL_COMMON).detect { |s| s.metadata.labels[LABEL_UNIQUE] == uid }
      end

      def data
        data = { 'updated_at' => Time.now.utc.strftime("%Y-%m-%d %H:%M:%S") }

        config_map.sources.each do |source|
          next unless source.from_sources_api # don't add to secret if removed from API

          data[source['uid']] = source_to_data(source)

          # Azure has extra parameter "tenant_id"
          if source.source_type&.azure?
            tenant_id = source.azure_tenant.to_s
            data[source['uid']]['tenant_id'] = tenant_id if tenant_id.present?
          end
        end

        { "credentials" => data.to_json }
      end

      def source_to_data(source)
        {
          'username' => source.credentials['username'],
          'password' => source.credentials['password']
        }
      end
    end
  end
end
