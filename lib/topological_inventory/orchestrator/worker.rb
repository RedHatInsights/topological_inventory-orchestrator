require "active_support/core_ext/enumerable"
require "base64"
require "config"
require "json"
require "manageiq-password"
require "manageiq-messaging"
require "more_core_extensions/core_ext/hash"
require "rest-client"
require "yaml"

require "topological_inventory/orchestrator/logger"
require "topological_inventory/orchestrator/object_manager"
require "topological_inventory/orchestrator/api"
require "topological_inventory/orchestrator/config_map"
require "topological_inventory/orchestrator/deployment_config"
require "topological_inventory/orchestrator/event_manager"
require "topological_inventory/orchestrator/secret"
require "topological_inventory/orchestrator/source_type"
require "topological_inventory/orchestrator/source"

module TopologicalInventory
  module Orchestrator
    # Entrypoint
    # Each 10 seconds it synchronizes Sources/Topological db with Openshift pods
    class Worker
      include Logging

      ORCHESTRATOR_TENANT = "system_orchestrator".freeze

      attr_reader :api, :enabled_source_types, :metrics

      def initialize(config_name: 'default',
                     metrics: nil,
                     source_types: %w[amazon ansible-tower azure openshift],
                     sources_api:,
                     topology_api:)
        @enabled_source_types = source_types

        self.metrics     = metrics
        self.config_name = config_name
        initialize_config

        @api = Api.new(:metrics => metrics, :sources_api => sources_api, :topology_api => topology_api)
      end

      def run
        remove_deprecated_objects

        if ENV['NO_KAFKA'].to_i == 1
          loop do
            make_openshift_match_database

            sleep (::Settings.sync.poll_time_seconds || 10).seconds
          end
        else
          EventManager.run!(self)
        end
      end

      def make_openshift_match_database
        # Clean up any errored deploy-pods
        cleanup_errored_deployment_configs

        # Assign sources_per_collector from config
        load_source_types

        # Load sources, assign source_types, mark found_in_api: true
        load_sources

        # Assign source types and sources
        load_config_maps

        # Assign config maps
        load_secrets

        # Assign config maps
        load_deployment_configs

        # Adds or removes sources to/from openshift
        manage_openshift_collectors

        # Remove unused openshift objects
        remove_old_deployments
        remove_old_secrets
        remove_completed_deploy_pods
      end

      protected

      def object_manager
        @object_manager ||= ObjectManager.new(metrics)
      end

      attr_accessor :config_name,
                    :source_types_by_id, :sources_by_digest,
                    :config_maps_by_uid, :deployment_configs, :secrets

      attr_writer :metrics

      def load_source_types
        @source_types_by_id = {}

        @api.each_source_type do |attributes|
          attributes[:enabled?] = @enabled_source_types.include?(attributes['name'])

          if (source_type = SourceType.new(attributes)).supported_source_type?
            logger.debug("Loaded Source type: #{attributes['name']} | #{source_type.sources_per_collector} sources per config map")
          end

          attributes["collector_image"] = get_collector_image(attributes['name'])
          @source_types_by_id[attributes['id']] = source_type
        end
      end

      # Loads Sources from Topological API and Sources API
      # Also loads endpoint and credentials for each source
      def load_sources
        @sources_by_digest = {}

        @api.each_source do |attributes, tenant|
          begin
            if (source_type = @source_types_by_id[attributes['source_type_id']]).nil?
              logger.error("Source #{attributes['id']}: Source Type not found (#{attributes['source_type_id']})")
              metrics&.record_error(:source_type_not_found)
              next
            end

            unless source_type.supported_source_type?
              logger.debug("Source #{attributes['id']}: Source Type not supported (#{source_type['name']})")
              next
            end

            if source_type.supports_availability_check?
              next unless attributes["availability_status"] == "available"
            end

            if source_type["collector_image"].nil?
              logger.error("Source #{attributes['id']}: Collector Image for Source Type not found (#{source_type['name']})")
              metrics&.record_error(:image_not_found)
              next
            end

            Source.new(attributes, tenant, source_type, :from_sources_api => true).tap do |source|
              source.load_credentials(@api)

              @sources_by_digest[source.digest] = source if source.digest.present?
            end
          rescue => err
            logger.error("Failed to load source #{attributes["name"]}: #{err}\n#{err.backtrace.join("\n")}")
            metrics&.record_error(:load_sources)
          end
        end

        logger.debug("Sources loaded: #{@sources_by_digest.values.count}")
      end

      # Load config maps from OpenShift and pairs them with
      # - source types collected from API
      # - sources collected from API
      def load_config_maps
        @config_maps_by_uid, by_type = {}, {}

        object_manager.get_config_maps("#{ConfigMap::LABEL_COMMON}=#{::Settings.labels.version}").each do |openshift_object|
          config_map = ConfigMap.new(object_manager, openshift_object)
          @config_maps_by_uid[config_map.uid] = config_map

          config_map.assign_source_type!(@source_types_by_id.values)

          # Assign sources by digest (or create new source)
          config_map.associate_sources(@sources_by_digest)

          # Remember metrics
          src_type_name = config_map.source_type.try(:[], 'name')
          by_type[src_type_name] = by_type[src_type_name].to_i + 1
        end

        # Set metrics
        by_type.each_pair do |source_type_name, cnt|
          metrics&.record_config_maps(:value => cnt, :source_type => source_type_name)
        end

        logger.debug("ConfigMaps loaded: #{@config_maps_by_uid.values.count}")
      end

      # Loads deployment configs(DC) from Openshift and pairs them with config maps
      # Then creates deployment configs for config maps which doesn't have it's associated DC (i.e. manually deleted)
      def load_deployment_configs
        @deployment_configs, by_type = [], {}

        object_manager.get_deployment_configs("#{DeploymentConfig::LABEL_COMMON}=#{::Settings.labels.version}").each do |openshift_object|
          deployment_config = DeploymentConfig.new(object_manager, openshift_object)
          @deployment_configs << deployment_config

          next if deployment_config.uid.nil?

          if (map = @config_maps_by_uid[deployment_config.uid]).present?
            map.deployment_config = deployment_config
            deployment_config.config_map = map

            # Remember metrics
            src_type_name = map.source_type.try(:[], 'name')
            by_type[src_type_name] = by_type[src_type_name].to_i + 1
          end
        end

        # Set metrics
        by_type.each_pair do |source_type_name, cnt|
          metrics&.record_deployment_configs(:value => cnt, :source_type => source_type_name)
        end

        create_missing_deployment_configs

        logger.debug("DeploymentConfigs loaded: #{@deployment_configs.count}")
      end

      # Loads secrets from Openshift and pairs them with config maps
      # Then creates secrets for config maps which doesn't have it's associated secret (i.e. manually deleted)
      def load_secrets
        @secrets, by_type = [], {}

        object_manager.get_secrets("#{Secret::LABEL_COMMON}=#{::Settings.labels.version}").each do |openshift_object|
          secret = Secret.new(object_manager, openshift_object)
          @secrets << secret

          next if secret.uid.nil?

          if (map = @config_maps_by_uid[secret.uid]).present?
            map.secret = secret
            secret.config_map = map

            # Remember metrics
            src_type_name = map.source_type.try(:[], 'name')
            by_type[src_type_name] = by_type[src_type_name].to_i + 1
          end
        end

        # Set metrics
        by_type.each_pair do |source_type_name, cnt|
          metrics&.record_secrets(:value => cnt, :source_type => source_type_name)
        end

        create_missing_secrets

        logger.debug("Secrets loaded: #{@secrets.count}")
      end

      # Add new sources to openshift and updates source refresh status in Topological API
      # Remove old sources from openshift
      def manage_openshift_collectors
        @sources_by_digest.values.dup.each do |source|
          #
          # a) source deleted from Sources API
          #
          if !source.from_sources_api && source.config_map.present?
            # TODO: Don't remove if not last source in config map
            @config_maps_by_uid.delete(source.config_map.uid) if source.config_map.present?
            @sources_by_digest.delete(source.digest)

            source.remove_from_openshift
          #
          # b) new source created in Sources API
          #
          elsif source.from_sources_api && source.config_map.nil?
            begin
              source.add_to_openshift(object_manager, @config_maps_by_uid.values)

              @config_maps_by_uid[source.config_map.uid] = source.config_map if source.config_map.present?

              @api.update_topological_inventory_source_refresh_status(source, "deployed")
            rescue TopologicalInventory::Orchestrator::ObjectManager::QuotaError
              logger.info("Skipping Deployment Config creation for source #{source["id"]} because it would exceed quota.")
              metrics&.record_error(:quota_error)
              @api.update_topological_inventory_source_refresh_status(source, "quota_limited")

              # Remove config map and secret if they exist
              source.remove_from_openshift
            end
          #
          # c) Source was found in Sources API and Config map, but zero Pods present (deployment has failed)
          #
          elsif source.config_map.deployment_config.openshift_object.status.availableReplicas == 0
            # retry the deployment by deleting and re-creating the deployment
            source.config_map.deployment_config.recreate_in_openshift
          else
            logger.debug("Source not changed (#{source})")
          end
        end

        # Sync the collectors for each configmap just in case an image
        # or resource settings changed but the config map stayed the same
        sync_running_collectors
      end

      def sync_running_collectors
        sync_collector_images
        sync_collector_resources
      end

      def sync_collector_images
        @config_maps_by_uid.values.each do |cm|
          # Only sync if the image has changed
          next if cm.source_type["collector_image"] == cm.deployment_config.image

          cm.deployment_config.update_image(cm.source_type["collector_image"])
        end
      end

      def sync_collector_resources
        @config_maps_by_uid.values.each do |cm|
          # Only sync if the resources do not match what is configured
          next if object_manager.collector_resources == cm.deployment_config.resources

          cm.deployment_config.sync_resources
        end
      end

      # Self recovery
      # If config map doesn't have secret (deleted from outside), create new
      def create_missing_secrets
        @config_maps_by_uid.each_value do |map|
          next if map.secret.present?

          map.create_secret
        end
      end

      # Self recovery
      # If config map doesn't have deployment config (deleted from outside), create new
      def create_missing_deployment_configs
        @config_maps_by_uid.each_value do |map|
          next if map.deployment_config.present?

          begin
            map.create_deployment_config
          rescue TopologicalInventory::Orchestrator::ObjectManager::QuotaError
            logger.info("Skipping Deployment Config creation for config map #{map} because it would exceed quota.")
            metrics&.record_error(:quota_error)
          end
        end
      end

      # Remove deployment configs without config maps with the same UID
      def remove_old_deployments
        @deployment_configs.to_a.each do |dc|
          dc.delete_in_openshift if dc.config_map.nil?
        end
      end

      # Remove secrets without config maps with the same UID
      def remove_old_secrets
        @secrets.to_a.each do |secret|
          secret.delete_in_openshift if secret.config_map.nil?
        end
      end

      # Get the collector image tag
      def get_collector_image(type)
        object_manager.get_collector_image(type)
      end

      # Deprecated version of openshift objects should be deleted before sync starts
      # version is determined by config's "labels.version" value of common labels' values
      def remove_deprecated_objects
        logger.info("Deleting deprecated objects...")

        remove_deprecated_deployment_configs
        remove_deprecated_config_maps
        remove_deprecated_secrets

        logger.info("Deleting deprecated objects...[OK]")
      rescue => err
        logger.info("Deleting deprecated objects...[ERROR] #{err}\n#{err.backtrace.join("\n")}")
      end

      def remove_deprecated_config_maps
        config_maps = object_manager.get_config_maps(ConfigMap::LABEL_COMMON).select do |obj|
          obj.metadata.labels[ConfigMap::LABEL_COMMON] != ::Settings.labels.version
        end
        names = []
        config_maps.each do |config_map|
          name = config_map.metadata.name
          names << name

          source_type = config_map.metadata.labels[TopologicalInventory::Orchestrator::ConfigMap::LABEL_SOURCE_TYPE]
          object_manager.delete_config_map(name, source_type)
        end
        logger.info("Deleting deprecated ConfigMaps: [#{names.join(', ')}]")
      end

      def remove_deprecated_deployment_configs
        dcs = object_manager.get_deployment_configs(DeploymentConfig::LABEL_COMMON).select do |obj|
          obj.metadata.labels[DeploymentConfig::LABEL_COMMON] != ::Settings.labels.version
        end
        names = []
        dcs.each do |dc|
          name = dc.metadata.name
          names << name
          object_manager.delete_deployment_config(name)
        end
        logger.info("Deleting deprecated DeploymentConfigs: [#{names.join(', ')}]")
      end

      def remove_deprecated_secrets
        secrets = object_manager.get_secrets(Secret::LABEL_COMMON).select do |obj|
          obj.metadata.labels[Secret::LABEL_COMMON] != ::Settings.labels.version
        end
        names = []
        secrets.each do |secret|
          name = secret.metadata.name
          names << name
          object_manager.delete_secret(name)
        end
        logger.info("Deleting deprecated Secrets: [#{names.join(', ')}]")
      end

      def cleanup_errored_deployment_configs
        # Get the pods in `Failed` status and are deploy pods
        pods = object_manager.get_pods.select { |e| e.status.phase == "Failed" && e.metadata.name.match?(/^collector.*\d+-deploy$/) }

        logger.info("Deleting failed DeploymentConfigs: [#{pods.map { |pod| pod.metadata.annotations["openshift.io/deployment-config.name"] }}]")

        pods.each do |pod|
          object_manager.delete_deployment_config(pod.metadata.annotations["openshift.io/deployment-config.name"])
        end
      end

      def remove_completed_deploy_pods
        pods = object_manager.get_pods.select { |e| e.status.phase == "Succeeded" && e.metadata.name.match?(/^collector.*\d+-deploy$/) }

        logger.info("Deleting dangling deploy pods: [#{pods.map { |pod| pod.metadata.name }.join(",")}]")
        pods.each do |pod|
          object_manager.delete_pod(pod.metadata.name)
        end
      end

      def initialize_config
        config_file = File.join(self.class.path_to_config, "#{sanitize_filename(config_name)}.yml")
        raise "Configuration file #{config_file} doesn't exist" unless File.exist?(config_file)

        ::Config.load_and_set_settings(config_file)
      end

      def self.path_to_config
        File.expand_path("../../../config", File.dirname(__FILE__))
      end

      def sanitize_filename(filename)
        # Remove any character that isn't 0-9, A-Z, or a-z, / or -
        filename.gsub(/[^0-9A-Z\/\-]/i, '_')
      end
    end
  end
end
