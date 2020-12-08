require "yaml"
require "topological_inventory/orchestrator/openshift_object"

module TopologicalInventory
  module Orchestrator
    # The ConfigMap is identified by label LABEL_COMMON (not unique)
    # And by UUID, which is unique (data.uid)
    # This UUID is also written to associated deployment_config, secret and service
    class ConfigMap < OpenshiftObject
      LABEL_COMMON = "tp-inventory/collectors-config-map".freeze
      LABEL_UNIQUE = "tp-inventory/config-uid".freeze
      LABEL_SOURCE_TYPE = "tp-inventory/source-type".freeze

      attr_accessor :source_type, :sources, :targeted_update
      attr_writer :deployment_config, :secret, :service

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
        self.targeted_update = false
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
            source = Source.new({}, nil, source_type, :from_sources_api => false)
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

      def associate_sources_by_targets(targets)
        custom_yml_content[:sources].each do |yaml_source|
          targets.each do |target|
            next if target[:source].blank?
            next if target[:source]['uid'] != yaml_source[:source]

            target[:source].digest = yaml_source[:digest]
            target[:source].config_map = self
            sources << target[:source]
          end
        end
        sources.uniq!
      end

      # Adds Source to this ConfigMap and Secret
      # Collector's app reloads config map automatically
      def add_source(source)
        logger.info("Adding Source #{source} to ConfigMap #{self}")

        raise "ConfigMap not available" unless available?(source)

        if source.digest.present?
          if targeted_update
            upsert_one!(source)
          else
            if !digests.include?(source.digest)
              digests << source.digest
              sources << source
              update!
              logger.info("[OK] Added Source #{source} to ConfigMap #{self}")
            else
              logger.warn("[WARN] Trying to add already added source #{source} to ConfigMap #{self}")
            end
          end
        else
          logger.warn("[WARN] Trying to add source #{source} without digest to ConfigMap #{self}")
        end
      end

      # Targeted update's method:
      # Creates or updates source in openshift(custom.yml and digests)
      def update_source(source)
        logger.info("Updating Source #{source} from ConfigMap #{self}")

        upsert_one!(source)

        logger.info("[OK] Updated Source #{source} in ConfigMap")
      end

      # Remove Source from this ConfigMap and Secret
      # If no sources in ConfigMap left, delete it, secret and DC (DeploymentConfig)
      def remove_source(source)
        logger.info("Removing Source #{source} from ConfigMap #{self}")

        digests.delete(source.digest) if source.digest.present?
        sources.delete(source)

        targeted_delete(source) if targeted_update

        if sources_count.zero?
          delete_in_openshift
        else
          update! unless targeted_update
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

        object_manager.create_config_map(name, source_type_name) do |map|
          map[:metadata][:labels][LABEL_COMMON] = ::Settings.labels.version.to_s
          map[:metadata][:labels][LABEL_SOURCE_TYPE] = source_type_name if source_type.present?
          map[:metadata][:labels][LABEL_UNIQUE] = uid
          map[:data][:uid] = uid
          map[:data][:digests] = [source.digest].to_json
          map[:data]["custom.yml"] = yaml_from_sources
        end

        logger.info("[OK] Created ConfigMap #{self}")

        create_secret

        create_deployment_config

        create_service
      end

      def create_secret
        @secret = new_secret.tap do |s|
          s.config_map = self
        end
        @secret.create_in_openshift
      end

      # Lazy load
      def secret
        return @secret if @secret.present?

        secret = new_secret.tap do |s|
          s.config_map = self
        end
        @secret = secret if secret.openshift_object.present?
      end

      def create_service
        @service = new_service.tap do |s|
          s.config_map = self
        end
        @service.create_in_openshift
      end

      # Lazy load
      def service
        return @service if @service.present?

        service = new_service.tap do |s|
          s.config_map = self
        end
        @service = service if service.openshift_object.present?
      end

      def create_deployment_config
        @deployment_config = new_deployment_config.tap do |dc|
          dc.config_map = self
        end
        @deployment_config.create_in_openshift
      end

      # Lazy load
      def deployment_config
        return @deployment_config if @deployment_config.present?

        dc = new_deployment_config.tap do |dc|
          dc.config_map = self
        end
        @deployment_config = dc if dc.openshift_object.present?
      end

      def delete_in_openshift
        service&.delete_in_openshift
        deployment_config&.delete_in_openshift
        secret&.delete_in_openshift

        logger.info("Deleting ConfigMap #{self}")

        object_manager.delete_config_map(name, source_type_name)

        logger.info("[OK] Deleted ConfigMap #{self}")
      end

      def name
        "config-#{source_type_name}-#{uid}"
      end

      # New ConfigMap is associated with random UUID
      def uid
        return @uid if @uid.present?

        @uid = if @openshift_object.nil? # no openshift_object reloading here (cycle)
                 generate_uniq_uid
               else
                 @openshift_object.data.uid
               end
      end

      private

      # Generates UID in loop until it exists in OpenShift
      def generate_uniq_uid
        generated = nil
        loop do
          generated = SecureRandom.hex(4)
          existing_object = load_openshift_object(generated)
          break if existing_object.nil?
        end
        generated
      end

      def yaml_from_sources
        cfg = {:sources => [], :updated_at => Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")}
        sources.each do |source|
          next unless source.from_sources_api

          cfg[:sources] << source_to_yaml(source)
        end

        cfg.to_yaml
      end

      def source_to_yaml(source)
        {
          :source         => source['uid'],
          :source_id      => source['id'],
          :source_name    => source['name'],
          :scheme         => source.endpoint['scheme'],
          :host           => source.endpoint['host'],
          :port           => source.endpoint['port'],
          :path           => source.endpoint['path'],
          :receptor_node  => source.endpoint['receptor_node'],
          :account_number => source.tenant,
          :image_tag_sha  => source.source_type['collector_image'].split(":").last,
          :digest         => source.digest
        }
      end

      # Parsed content of custom.yml
      def custom_yml_content(reload: false)
        return @yaml if @yaml.present? && !reload

        @yaml = YAML.load(openshift_object.data['custom.yml'])
      end

      # Updates digests in openshift object's data
      def update!
        raise "Missing openshift object" if openshift_object.nil?

        save_config_map(digests.to_json, yaml_from_sources)

        secret&.update!
      end

      # Insert or update for targeted update
      # @param source [Orchestrator::Source]
      def upsert_one!(source)
        raise "Missing openshift object" if openshift_object.nil?

        custom_yml_data = custom_yml_content

        # Update Source
        logger.debug("UpdateOne: YAML: #{custom_yml_data[:sources]} | Source: #{source}")
        found = (idx = custom_yml_data[:sources].index { |yaml_source| yaml_source[:source] == source['uid'] }).present?

        new_digest = source.digest(:reload => true)
        if found
          old_digest = custom_yml_data[:sources][idx][:digest]
          custom_yml_data[:sources][idx] = source_to_yaml(source)
        else
          custom_yml_data[:sources] << source_to_yaml(source)
        end

        # Update Digests
        digests.delete(old_digest) if found
        digests << new_digest

        # Update Time
        custom_yml_data[:updated_at] = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")

        save_config_map(digests.to_json, custom_yml_data.to_yaml)

        # Update Secret
        secret&.upsert_one!(source)
      end

      def targeted_delete(source)
        raise "Missing openshift object" if openshift_object.nil?

        # Search for source in custom.yml
        custom_yml_data = custom_yml_content
        found = (idx = custom_yml_data[:sources].index { |yaml_source| yaml_source[:source] == source['uid'] }).present?
        unless found
          logger.warn("Targeted delete (Source #{source}): Not found in ConfigMap #{self}")
          return
        end

        old_digest = custom_yml_data[:sources][idx][:digest]

        # Remove from custom.yml and digests
        custom_yml_data[:sources].delete_at(idx)
        digests.delete(old_digest)

        # Update Time
        custom_yml_data[:updated_at] = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")

        # Will be deleted by remove_source()
        if sources_count > 0
          # Save Config Map
          save_config_map(digests.to_json, custom_yml_data.to_yaml)
          # Update Secret
          secret&.targeted_delete(source)
        end
      end

      def save_config_map(digests_json, data_yaml)
        openshift_object.data.digests = digests_json
        openshift_object.data['custom.yml'] = data_yaml

        object_manager.update_config_map(openshift_object)
        openshift_object(:reload => true)
      end

      def digests
        return @digests if @digests

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
        current = sources_count
        max = source_type&.sources_per_collector || 1

        is_free = current < max

        logger.debug("ConfigMap #{self}: Free slot? (max: #{max}, current: #{current}): #{is_free ? 'T' : 'F'}")
        is_free
      end

      # For full update all sources are loaded, for targeted update, load count from custom.yml
      def sources_count
        if targeted_update
          custom_yml_content[:sources].size
        else
          sources.size
        end
      end

      def source_type_name
        source_type.try(:[], 'name') || 'unknown'
      end

      def new_secret
        Secret.new(object_manager)
      end

      def new_service
        Service.new(object_manager)
      end

      def new_deployment_config
        DeploymentConfig.new(object_manager)
      end

      def load_openshift_object(object_uid = uid)
        object_manager.get_config_maps(LABEL_COMMON).detect { |s| s.metadata.labels[LABEL_UNIQUE] == object_uid }
      end
    end
  end
end
