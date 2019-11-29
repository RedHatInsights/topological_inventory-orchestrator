require "yaml"
require "topological_inventory/orchestrator/openshift_object"

module TopologicalInventory
  module Orchestrator
    # The ConfigMap is identified by label LABEL_COMMON (not unique)
    # And by UUID, which is unique (data.uid)
    # This UUID is also written to associated deployment_config and secret
    class ConfigMap < OpenshiftObject
      LABEL_COMMON = "tp-inventory/collectors-config-map".freeze
      LABEL_UNIQUE = "tp-inventory/config-uid".freeze
      LABEL_SOURCE_TYPE = "tp-inventory/source-type".freeze

      attr_accessor :deployment_config, :secret, :source_type, :sources

      def to_s
        str = "#{uid} [#{sources.count} sources]"
        str += " (#{source_type})" if source_type.present?
        str
      end

      # Found new Source and no available ConfigMap + DC + Secret
      def self.deploy_new(object_manager, source)
        config_map = self.new(object_manager, nil)
        source.config_map = config_map
        config_map.init_from_source!(source)
        config_map
      end

      def initialize(object_manager, openshift_object)
        super(object_manager, openshift_object)

        self.source_type = nil
        self.sources = []
      end

      # Creates new ConfigMap, DeploymentConfig, Secret in **openshift**
      # @param source [Source]
      def init_from_source!(source)
        self.source_type = source.source_type
        self.sources << source

        create_in_openshift(source)
      end

      # Connects ConfigMap's label and SourceType
      # @param source_types [Array<SourceType>]
      def assign_source_type!(source_types)
        source_type_name = source_type_by_label

        source_types.each do |st|
          if st['name'] == source_type_name
            self.source_type = st
          end
        end
      end

      # Pairs Sources(API) with ConfigMap (Source's digest with digests list loaded from ConfigMap)
      #
      # Either finds `Source(:from_sources_api => true)` in sources_by_digest (found on both sides, no change)
      #  or creates marker for deleting `Source(:from_sources_api => false)` from ConfigMap
      #
      # @param [Hash<String,Source>] sources_by_digest<digest, Source(:from_sources_api => true)>
      def associate_sources(sources_by_digest)
        digests.each do |digest|
          source = sources_by_digest[digest]
          if source.nil?
            # This source is not in API, will be deleted from openshift
            source = Source.new({}, nil, source_type, nil, :from_sources_api => false)
            source.digest = digest
            sources_by_digest[digest] = source
            logger.debug("Assoc Map (#{uid}) -> Source (digest #{digest}) not found")
          else
            logger.debug("Assoc Map (#{uid}) -> Source (digest #{digest}) found: #{source}")
          end
          source.config_map = self
          sources << source
        end
        sources_by_digest
      end

      # Adds Source to this ConfigMap and Secret
      # Collector's app reloads config map automatically
      def add_source(source)
        logger.info("Adding Source #{source} to ConfigMap #{self}")

        raise "ConfigMap not available" unless available?(source)

        if source.digest.present?
          if !digests.include?(source.digest)
            digests << source.digest
            sources << source
            update!
            logger.info("[OK] Added Source #{source} to ConfigMap #{self}")
          else
            logger.warn("[WARN] Trying to add already added source #{source} to ConfigMap #{self}")
          end
        else
          logger.warn("[WARN] Trying to add source #{source} without digest to ConfigMap #{self}")
        end
      end

      # Remove Source from this ConfigMap and Secret
      # If no sources in ConfigMap left, delete it, secret and DC (DeploymentConfig)
      def remove_source(source)
        logger.info("Removing Source #{source} from ConfigMap #{self}")

        digests.delete(source.digest) if source.digest.present?
        sources.delete(source)

        if sources.size.zero?
          delete_in_openshift
        else
          update!
        end

        logger.info("[OK] Removed Source #{source} from ConfigMap #{self}")
      end

      # Is config map available for source?
      # True if free space in sources array and the same source type
      def available?(source)
        compatible?(source) && free_slot?
      end

      # Creating new ConfigMap in OpenShift (when no existing available)
      # Also creates secret and deployment_config (connected by UID)
      def create_in_openshift(source)
        logger.info("Creating ConfigMap #{self} by Source #{source}")

        object_manager.create_config_map(name) do |map|
          map[:metadata][:labels][LABEL_COMMON] = "true"
          map[:metadata][:labels][LABEL_SOURCE_TYPE] = source_type['name'] if source_type.present?
          map[:metadata][:labels][LABEL_UNIQUE] = uid
          map[:data][:uid] = uid
          map[:data][:digests] = [source.digest].to_json
          map[:data]["custom.yml"] = yaml_from_sources
        end

        logger.info("[OK] Created ConfigMap #{self}")

        create_secret

        create_deployment_config
      end

      def create_secret
        self.secret = new_secret.tap do |s|
          s.config_map = self
        end
        secret.create_in_openshift
      end

      def create_deployment_config
        self.deployment_config = new_deployment_config.tap do |dc|
          dc.config_map = self
        end
        deployment_config.create_in_openshift
      end

      def delete_in_openshift
        deployment_config&.delete_in_openshift
        secret&.delete_in_openshift

        logger.info("Deleting ConfigMap #{self}")

        object_manager.delete_config_map(name)

        logger.info("[OK] Deleted ConfigMap #{self}")
      end

      def name
        type_name = source_type.present? ? source_type['name'] : 'unknown'
        "config-#{type_name}-#{uid}"
      end

      # New ConfigMap is associated with random UUID
      def uid
        return @uid if @uid.present?

        @uid = if @openshift_object.nil? # no openshift_object reloading here (cycle)
                 SecureRandom.uuid
               else
                 @openshift_object.data.uid
               end
      end

      private

      def yaml_from_sources
        cfg = {:sources => [], :updated_at => Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")}
        sources.each do |source|
          next unless source.from_sources_api

          cfg[:sources] << {
            :source      => source['uid'],
            :source_id   => source['id'],
            :source_name => source['name'],
            :scheme      => source.endpoint['scheme'],
            :host        => source.endpoint['host'],
            :port        => source.endpoint['port'],
            :path        => source.endpoint['path'],
          }
        end

        cfg.to_yaml
      end

      # Updates digests in openshift object's data
      def update!
        raise "Missing openshift object" if openshift_object.nil?

        openshift_object.data.digests = digests.to_json
        openshift_object.data['custom.yml'] = yaml_from_sources

        object_manager.update_config_map(openshift_object)

        secret&.update!
      end

      def digests
        return @digests if @digests.present?

        @digests = if openshift_object&.data&.digests.present?
                     JSON.parse(openshift_object.data.digests)
                   else
                     []
                   end
      end

      def source_type_by_label
        openshift_object.metadata.labels[LABEL_SOURCE_TYPE]
      end

      # Only ConfigMap and Source with same SourceType are compatible
      def compatible?(source)
        return false if source_type.nil? || source.source_type.nil?

        source_type['name'] == source.source_type['name']
      end

      # Maximum sources is set by config
      def free_slot?
        current = sources.size
        max = source_type&.sources_per_collector || 1

        is_free = current < max

        logger.debug("ConfigMap #{self}: Free slot? (max: #{max}, current: #{current}): #{is_free ? 'T' : 'F'}")
        is_free
      end

      def new_secret
        Secret.new(object_manager)
      end

      def new_deployment_config
        DeploymentConfig.new(object_manager)
      end

      def load_openshift_object
        object_manager.get_config_maps(LABEL_COMMON).detect { |s| s.metadata.labels[LABEL_UNIQUE] == uid }
      end
    end
  end
end
