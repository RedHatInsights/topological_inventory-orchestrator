module TopologicalInventory
  module Orchestrator
    class TargetedUpdate
      module ApiLoadBelongsTo
        # @param src_models [Array<Symbol>]
        # @param dest_model [Symbol]
        # @param foreign_key [String] in each src_model
        def api_load_belongs_to(src_models, dest_model, foreign_key, targets = @targets)
          dest_ids, dest_targets = api_load_belongs_to_group_targets(foreign_key, src_models, targets)

          # Call API request for each tenant
          api_load_belongs_to_send(dest_model, dest_ids, dest_targets)
        end

        def api_load_belongs_to_group_targets(foreign_key, src_models, targets)
          dest_ids, dest_targets = {}, {}
          targets.each do |target|
            # Hash value means that this target contains loaded data we need
            target_model = src_models.select { |model| target[model].present? }.first
            next if target_model.nil?

            target_data = target[target_model]
            dest_id     = target_data[foreign_key].to_i

            # Collect ids by tenants (each tenant requires separate API request)
            dest_ids[target_data['tenant']] ||= []
            dest_ids[target_data['tenant']] << dest_id

            dest_targets[dest_id] ||= []
            dest_targets[dest_id] << target
          end

          [dest_ids, dest_targets]
        end

        def api_load_belongs_to_send(dest_model, dest_ids, dest_targets)
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
      end
    end
  end
end
