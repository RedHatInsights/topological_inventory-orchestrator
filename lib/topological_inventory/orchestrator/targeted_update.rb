require "topological_inventory/orchestrator/targeted_api"

module TopologicalInventory
  module Orchestrator
    class TargetedUpdate < Worker
      attr_reader :targets

      def initialize(worker)
        @collector_image_tag = worker.collector_image_tag
        @api = TargetedApi.new(:sources_api => worker.api.sources_api,
                               :topology_api => worker.api.topology_api)

        @targets = []
      end

      # @param action [String] - :create, :update, :destroy. Can be changed to :destroy, :skip
      def add_target(model, action, model_data)
        logger.debug("*** Received #{model}:#{action}(ID #{model_data['id']}) ***")
        target_model = model.downcase.to_sym
        target = { :target => target_model,
                   :action => action.to_sym,
                   :application => nil,
                   :authentication => nil,
                   :endpoint => nil,
                   :source => nil,
                   :source_type => nil,
                   :tenant => nil }

        target[target_model] = hash_to_api_object(model_data, target_model)
        # Tenant.external_tenant value
        target[:tenant] = model_data['tenant'] # All tables/events have "tenant"

        @targets << target
      end

      def sync_targets_with_openshift
        load_sources_from_targets

        scan_targets

        load_credentials_for_upsert

        load_config_maps

        manage_openshift_collectors
      end

      private

      def load_sources_from_targets
        api_load_belongs_to(%i[authentication], :endpoint, 'resource_id')
        api_load_belongs_to(%i[endpoint application], :source, 'source_id')
        api_load_belongs_to(%i[source], :source_type, 'source_type_id')
        # assert_all_sources_loaded!
      end

      # TODO: Scan duplicates
      def scan_targets
        @sources_by_uid = {}

        @targets.each do |target|
          next unless check_source_loaded(target)
          next unless check_source_type_loaded(target)

          source, source_type = target[:source], target[:source_type]
          source.collector_definition = source_type.collector_definition(collector_image_tag)
          source.source_type = source_type
          source['id'] = source['id'].to_s # if source came from event, id is integer, otherwise string

          next unless check_source_type_supported(target)
          check_source_availability_status(target)

          @sources_by_uid[source['uid']] = source
        end
      end

      def load_credentials_for_upsert
        @targets.each do |target|
          next unless %i[create update].include?(target[:action])

          # Load Endpoint
          api_load_has_one(:source, :endpoint, 'source_id')
          next if target[:endpoint].nil?

          target[:source].endpoint = target[:endpoint]

          # Load Authentication
          api_load_has_one(:endpoint, :authentication, 'resource_id')
          next if target[:authentication].nil?

          target[:source].authentication = target[:authentication]
          target[:source].credentials = @api.get_credentials(target[:authentication]['id'], target[:tenant])
        end
      end

      def load_config_maps
        @config_maps_by_uid = {}

        object_manager.get_config_maps("#{ConfigMap::LABEL_COMMON}=true").each do |openshift_object|
          config_map = ConfigMap.new(object_manager, openshift_object)
          config_map.targeted_update = true

          @config_maps_by_uid[config_map.uid] = config_map

          config_map.assign_source_type!(@targets.collect { |t| t[:source_type] })
          config_map.associate_sources_by_uid(@sources_by_uid)
        end

        logger.debug("ConfigMaps loaded: #{@config_maps_by_uid.values.count}")
      end

      # TODO @api.update_topological_inventory_source_refresh_status
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
            target[:source].update_in_openshift
          when :create
            log_msg_for_target(target, "Source #{target[:source]['id']} create", :info)
            target[:source].add_to_openshift(object_manager, @config_maps_by_uid.values)
          end
        end
      end

      def api_load_has_one(src_model, dest_model, foreign_key)
        @targets.each do |target|
          next if target[dest_model].present? # Was loaded previously

          target_data = target[src_model]

          @api.send("each_#{dest_model}",
                    target_data['tenant'],
                    :filter_key   => foreign_key,
                    :filter_value => target_data['id'].to_i,
                    :limit        => 1) do |data|
            target[dest_model] = hash_to_api_object(data)
          end

          # If relation not found, something was wrong, delete from collectors
          if target[dest_model].nil?
            log_msg_for_target(target, "#{dest_model} not found, action changed to: 'destroy'")
            target[:action] = :destroy
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
                    :filter_key => 'id',
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

      def check_resource_loaded(target, resource_type)
        if target[resource_type].nil?
          log_msg_for_target(target, "#{resource_type.to_s.titleize} not found")
          target[:action] = :skip
          return false
        end
        true
      end

      def check_source_loaded(target)
        check_resource_loaded(target, :source)
      end

      def check_source_type_loaded(target)
        check_resource_loaded(target, :source_type)
      end

      def check_source_type_supported(target)
        return if (source_type = target[:source_type]).nil?
        unless source_type.supported_source_type?
          log_msg_for_target(target,"Source Type not supported (#{source_type['name']}), action changed to: 'destroy'", :debug)
          target[:action] = :destroy
          return false
        end
        true
      end

      def check_source_availability_status(target)
        return if (source = target[:source]).nil?

        if source['availability_status'] != 'available'
          target[:action] = :destroy
          return false
        end
        true
      end

      def log_msg_for_target(target, msg, severity = :error)
        prefix = "*** Event #{target[:target].to_s.titleize}:#{target[:action]}(ID #{target[target[:target]]['id']}) ***"
        logger.send(severity, "#{prefix} | #{msg}")
      end
    end
  end
end
