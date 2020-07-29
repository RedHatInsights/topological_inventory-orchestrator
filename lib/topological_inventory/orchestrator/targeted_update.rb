require "topological_inventory/orchestrator/targeted_api"

module TopologicalInventory
  module Orchestrator
    class TargetedUpdate < Worker
      require "topological_inventory/orchestrator/targeted_update/destroy_action_rules"
      require "topological_inventory/orchestrator/targeted_update/skip_action_rules"
      require "topological_inventory/orchestrator/targeted_update/api_load_helpers"

      include DestroyActionRules
      include SkipActionRules
      include ApiLoadHelpers

      attr_reader :targets

      def initialize(worker)
        @api = TargetedApi.new(:sources_api  => worker.api.sources_api,
                               :topology_api => worker.api.topology_api)
        @enabled_source_types = worker.enabled_source_types

        clear_targets
      end

      # Target (alias event) contains target model and target action.
      #
      # For every target (except with action :destroy) all related models
      #   has to be loaded from Sources API ( + Topological API)
      #
      # @param model [String]
      # @param action [String] - :create, :update, :destroy. Can be changed to :destroy, :skip
      # @param model_data [Hash]
      def add_target(model, action, model_data)
        logger.debug("*** Received #{model}:#{action}(ID #{model_data['id']}) ***")
        target_model = model.downcase.to_sym
        target = {:target         => target_model,
                  :action         => action.to_sym,
                  :application    => nil,
                  :authentication => nil,
                  :endpoint       => nil,
                  :source         => nil,
                  :source_type    => nil,
                  :tenant         => nil}

        target[target_model] = hash_to_api_object(model_data, target_model)
        # Tenant.external_tenant value
        target[:tenant] = model_data['tenant'] # All tables/events have "tenant"

        @targets << target
      end

      def clear_targets
        @targets = []
      end

      def sync_targets_with_openshift
        skip_unsupported_applications

        load_sources_from_targets

        load_source_types_from_targets

        load_applications

        scan_targets!

        load_credentials_for_upsert

        skip_targets_with_same_source_and_action

        load_config_maps

        manage_openshift_collectors
      end

      private

      def load_source_types_from_targets
        @targets.each do |target|
          source_type = target[:source_type]
          next unless source_type

          source_type[:enabled?] = @enabled_source_types.include?(source_type['name'])
          source_type["collector_image"] = object_manager.get_collector_image(source_type['name'])
        end
      end

      # Skips inconsistent data (if source not found) and noop destroy events
      # Assigns source type etc. to source
      # Switch action to "destroy" if source isn't available or supported
      def scan_targets!
        @targets.each do |target|
          next if skip_targets_without_source(target)
          next if skip_create_action_of_non_first_app(target)
          next if skip_destroy_action_of_non_last_app(target)

          source, source_type = target[:source], target[:source_type]
          source.source_type = source_type
          source['id'] = source['id'].to_s # if source came from event, id is integer, otherwise string

          force_destroy_action(target)
        end
      end

      # Loads config maps and assigns them to loaded Sources
      def load_config_maps
        @config_maps_by_uid = {}

        object_manager.get_config_maps("#{ConfigMap::LABEL_COMMON}=#{::Settings.labels.version}").each do |openshift_object|
          config_map = ConfigMap.new(object_manager, openshift_object)
          config_map.targeted_update = true

          @config_maps_by_uid[config_map.uid] = config_map

          config_map.assign_source_type!(@targets.collect { |t| t[:source_type] unless t[:action] == :skip }.compact)
          config_map.associate_sources_by_targets(@targets.select { |t| t[:action] != :skip})
        end

        logger.debug("ConfigMaps loaded: #{@config_maps_by_uid.values.count}")
      end

      # Main action! adds/updates or deletes source from config map
      # Empty config maps are deleted (together with DC and Secret)
      def manage_openshift_collectors
        @targets.each do |target|
          target[:action] = :create if target[:action] == :update && target[:source].config_map.blank?

          case target[:action]
          when :skip
            skip_target(target)
          when :destroy
            destroy_target(target)
          when :update
            update_target(target)
          when :create
            create_target(target)
          end
        end
      end

      def skip_target(target)
        return if target[:source].nil?

        log_msg_for_target(target, "Source #{target[:source]['id']} skipped", :info)
      end

      def destroy_target(target)
        log_msg_for_target(target, "Source #{target[:source]['id']} destroy", :info)
        target[:source].remove_from_openshift
      end

      def update_target(target)
        log_msg_for_target(target, "Source #{target[:source]['id']} update", :info)
        config_map = target[:source].update_in_openshift
        config_map.targeted_update = true
        @config_maps_by_uid[config_map.uid] = config_map
      end

      def create_target(target)
        log_msg_for_target(target, "Source #{target[:source]['id']} create", :info)
        config_map = target[:source].add_to_openshift(object_manager, @config_maps_by_uid.values)
        config_map.targeted_update = true
        @config_maps_by_uid[config_map.uid] = config_map
        @api.update_topological_inventory_source_refresh_status(target[:source], "deployed")
      rescue TopologicalInventory::Orchestrator::ObjectManager::QuotaError
        log_msg_for_target(target, "Skipping Deployment Config creation for source #{target[:source]['id']} because it would exceed quota")
        @api.update_topological_inventory_source_refresh_status(target[:source], "quota_limited")
        destroy_target(target)
      end

      def log_msg_for_target(target, msg, severity = :error)
        prefix = "#{target[:target].to_s.titleize}:#{target[:action]}(ID #{target[target[:target]]['id']})"
        logger.send(severity, "#{prefix} | #{msg}")
      end
    end
  end
end
