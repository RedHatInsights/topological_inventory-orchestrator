require "topological_inventory/orchestrator/targeted_api"

module TopologicalInventory
  module Orchestrator
    class TargetedUpdate < Worker
      attr_reader :targets

      def initialize(worker)
        @collector_image_tag = worker.collector_image_tag
        @api = TargetedApi.new(:sources_api  => worker.api.sources_api,
                               :topology_api => worker.api.topology_api)

        @targets = []
      end

      def clear_targets
        @targets = []
      end

      # @param action [String] - :create, :update, :destroy. Can be changed to :destroy, :skip
      def add_target(model, action, model_data)
        logger.debug("*** Received #{model}:#{action}(ID #{model_data['id']}) ***")
        target_model = model.downcase.to_sym
        target = { :target         => target_model,
                   :action         => action.to_sym,
                   :application    => nil,
                   :authentication => nil,
                   :endpoint       => nil,
                   :source         => nil,
                   :source_type    => nil,
                   :tenant         => nil }

        target[target_model] = hash_to_api_object(model_data, target_model)
        # Tenant.external_tenant value
        target[:tenant] = model_data['tenant'] # All tables/events have "tenant"

        @targets << target
      end

      def sync_targets_with_openshift
        skip_unsupported_applications

        load_sources_from_targets

        load_applications

        scan_targets!

        load_credentials_for_upsert

        skip_targets_with_same_source_and_action

        load_config_maps

        manage_openshift_collectors
      end

      private

      # If event is an application's event then only supported applications should be processed
      def skip_unsupported_applications
        app_events = @targets.select { |target| target[:target] == :application }

        if app_events.present?
          app_type_ids = @api.send(:supported_application_type_ids)
          app_events.each do |target|
            app = target[:application]
            unless app_type_ids.include?(app['application_type_id'].to_s)
              log_msg_for_target(target, "skipped as unsupported app (#{app.attributes})", :debug)
              target[:action] = :skip
            end
          end
        end
      end

      # API requests:
      # - source type for source
      # - source for endpoint
      # - source for application
      # - endpoint for authentication
      def load_sources_from_targets
        api_load_belongs_to(%i[authentication], :endpoint, 'resource_id')
        api_load_belongs_to(%i[endpoint application], :source, 'source_id')
        api_load_belongs_to(%i[source], :source_type, 'source_type_id')
      end

      # API Request: load supported applications for each source
      # Although source has_many applications, finding at least one supported is enough
      def load_applications
        api_load_has_one(:source, :application, 'source_id')
      end

      # Skips inconsistent data (if source not found)
      # Assigns source type etc. to source
      # Switch action to "destroy" if source isn't available or supported
      def scan_targets!
        @targets.each do |target|
          next if skip_targets_without_source(target)
          next if skip_destroy_action_of_non_last_app(target)

          source, source_type = target[:source], target[:source_type]
          source.collector_definition = source_type.collector_definition(collector_image_tag)
          source.source_type = source_type
          source['id'] = source['id'].to_s # if source came from event, id is integer, otherwise string

          force_destroy_action(target)
        end
      end

      # If Source or SourceType not loaded by API, something is wrong, skip this event
      def skip_targets_without_source(target)
        skip = (!source_loaded?(target) || !source_type_loaded?(target))

        target[:action] = :skip if skip
        skip
      end

      # If there are more supported applications, skip this 'destroy application' event
      def skip_destroy_action_of_non_last_app(target)
        if target[:action] == :destroy && target[:target] == :application
          orig_app = target[:application]
          target[:application] = nil
          load_applications

          if target[:application].present?
            log_msg_for_target(target, "Event skipped, another supported application found", :debug)
            target[:action] = :skip
          else
            target[:application] = orig_app
          end
        end
      end

      # Skip the same actions (i.e. creating a Source through UI generates multiple events)
      def skip_targets_with_same_source_and_action
        @targets.each do |target|
          @targets.each do |target2|
            next unless target[:source]['id'] == target2[:source]['id'] &&
                        target[:action] == target2[:action] &&
                        target[:target] != target2[:target]

            target[:action] = :skip
            break
          end
        end
      end

      def force_destroy_action(target)
        # Set action to :destroy if target doesn't pass
        check_source_type_supported(target) &&
          check_source_availability_status(target) &&
          check_for_supported_application(target)
      end

      # API requests: only "create", "update" actions
      # - loads missing endpoints (if event was from Application/Source)
      # - loads missing authentications (if event was from Application/Source/Endpoint)
      # - loads credentials (internal API/authentication)
      def load_credentials_for_upsert
        targets = @targets.select { |target| %i[create update].include?(target[:action]) }

        # Load Endpoint
        api_load_has_one(:source, :endpoint, 'source_id', targets)
        targets = targets.select { |target| target[:endpoint].present? }

        targets.each do |target|
          target[:source].endpoint = target[:endpoint]
        end

        # Load Authentication
        api_load_has_one(:endpoint, :authentication, 'resource_id', targets)
        targets = targets.select { |target| target[:authentication].present? }

        credentials = {}
        targets.each do |target|
          target[:source].authentication = target[:authentication]

          # cache credentials responses
          credentials[target[:authentication]['id']] ||= @api.get_credentials(target[:authentication]['id'], target[:tenant])
          target[:source].credentials = credentials[target[:authentication]['id']]
        end
      end

      # Loads config maps and assigns them to loaded Sources
      def load_config_maps
        @config_maps_by_uid = {}

        object_manager.get_config_maps("#{ConfigMap::LABEL_COMMON}=true").each do |openshift_object|
          config_map = ConfigMap.new(object_manager, openshift_object)
          config_map.targeted_update = true

          @config_maps_by_uid[config_map.uid] = config_map

          config_map.assign_source_type!(@targets.collect { |t| t[:source_type] })
          config_map.associate_sources_by_targets(@targets)
        end

        logger.debug("ConfigMaps loaded: #{@config_maps_by_uid.values.count}")
      end

      # Main action! adds/updates or deletes source from config map
      # Empty config maps are deleted (together with DC and Secret)
      # TODO: @api.update_topological_inventory_source_refresh_status
      def manage_openshift_collectors
        @targets.each do |target|
          target[:action] = :create if target[:action] == :update && target[:source].config_map.blank?

          case target[:action]
          when :skip then
            log_msg_for_target(target, "Source #{target[:source]['id']} skipped", :info)
            next
          when :destroy
            log_msg_for_target(target, "Source #{target[:source]['id']} destroy", :info)
            target[:source].remove_from_openshift
          when :update
            log_msg_for_target(target, "Source #{target[:source]['id']} update", :info)
            config_map = target[:source].update_in_openshift
            config_map.targeted_update = true
            @config_maps_by_uid[config_map.uid] = config_map
          when :create
            log_msg_for_target(target, "Source #{target[:source]['id']} create", :info)
            config_map = target[:source].add_to_openshift(object_manager, @config_maps_by_uid.values)
            config_map.targeted_update = true
            @config_maps_by_uid[config_map.uid] = config_map
          end
        end
      end

      def api_load_has_one(src_model, dest_model, foreign_key, targets = @targets)
        dest_ids, dest_targets = {}, {}
        targets.each do |target|
          next if target[dest_model].present? # Was loaded previously

          target_data = target[src_model]
          dest_id = target_data['id'].to_i

          dest_ids[target_data['tenant']] ||= []
          dest_ids[target_data['tenant']] << dest_id

          dest_targets[dest_id] ||= []
          dest_targets[dest_id] << target
        end

        dest_ids.each_pair do |external_tenant, ids|
          @api.send("each_#{dest_model}",
                    external_tenant,
                    :filter_key   => foreign_key,
                    :filter_value => ids.compact.uniq) do |data|
            api_object = hash_to_api_object(data)

            dest_targets[data[foreign_key].to_i].to_a.each do |target|
              target[dest_model] = api_object unless target.nil?
            end
          end
        end
      end

      # @param src_models [Array<Symbol>]
      # @param dest_model [Symbol]
      # @param foreign_key [String] in each src_model
      def api_load_belongs_to(src_models, dest_model, foreign_key)
        dest_ids, dest_targets = {}, {}
        @targets.each do |target|
          # Hash value means that this target contains loaded data we need
          target_model = src_models.select { |model| target[model].present? }.first
          next if target_model.nil?

          target_data = target[target_model]
          dest_id = target_data[foreign_key].to_i

          # Collect ids by tenants (each tenant requires separate API request)
          dest_ids[target_data['tenant']] ||= []
          dest_ids[target_data['tenant']] << dest_id

          dest_targets[dest_id] ||= []
          dest_targets[dest_id] << target
        end

        # Call API request for each tenant
        dest_ids.each_pair do |external_tenant, ids|
          next if external_tenant.nil? # TODO: log, inconsistent data

          @api.send("each_#{dest_model}",
                    external_tenant,
                    :filter_key   => 'id',
                    :filter_value => ids.compact.uniq) do |data|
            api_object = hash_to_api_object(data, dest_model)
            dest_targets[data['id'].to_i].to_a.each do |target|
              target[dest_model] = api_object unless target.nil?
            end
          end
        end
      end

      def hash_to_api_object(data, dest_model = nil)
        case dest_model
        when :source_type then SourceType.new(data)
        when :source then Source.new(data, data['tenant'], nil, nil, :from_sources_api => true)
        else ApiObject.new(data)
        end
      end

      def resource_loaded?(target, resource_type)
        if target[resource_type].nil?
          log_msg_for_target(target, "#{resource_type.to_s.titleize} not found")
        end
        target[resource_type].present?
      end

      def source_loaded?(target)
        resource_loaded?(target, :source)
      end

      def source_type_loaded?(target)
        resource_loaded?(target, :source_type)
      end

      def check_source_type_supported(target)
        return if (source_type = target[:source_type]).nil?

        unless source_type.supported_source_type?
          log_msg_for_target(target, "Source Type not supported (#{source_type['name']}), action changed to: 'destroy'", :debug)
          target[:action] = :destroy
          return false
        end
        true
      end

      def check_source_availability_status(target)
        return if (source = target[:source]).nil?

        if source['availability_status'] != 'available'
          log_msg_for_target(target, "Source unavailable (#{source}), action changed to: 'destroy'", :info)
          target[:action] = :destroy
          return false
        end
        true
      end

      def check_for_supported_application(target)
        if target[:application].blank?
          log_msg_for_target(target, "No supported application for Source (#{target[:source]}), action changed to: 'destroy'", :info)
          target[:action] = :destroy
          return false
        end
        true
      end

      def log_msg_for_target(target, msg, severity = :error)
        prefix = "#{target[:target].to_s.titleize}:#{target[:action]}(ID #{target[target[:target]]['id']})"
        logger.send(severity, "#{prefix} | #{msg}")
      end
    end
  end
end
