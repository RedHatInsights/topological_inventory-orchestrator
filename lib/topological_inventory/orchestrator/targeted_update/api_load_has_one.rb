module TopologicalInventory
  module Orchestrator
    class TargetedUpdate
      module ApiLoadHasOne
        # API request
        #
        # Loading has_one associations (API calls reduced to one request/tenant)
        # Sources db have defined has_many, but practically has_one is used (i.e. Source has_one Endpoint)
        def api_load_has_one(src_model, dest_model, foreign_key, targets = @targets)
          # Group targets by tenant
          dest_ids, dest_targets = api_load_has_one_group_targets(dest_model, src_model, targets)

          api_load_has_one_send(dest_model, foreign_key, dest_ids, dest_targets)
        end

        def api_load_has_one_group_targets(dest_model, src_model, targets)
          dest_ids, dest_targets = {}, {}

          targets.each do |target|
            next if target[dest_model].present? # Was loaded previously

            target_data = target[src_model]
            dest_id     = target_data['id'].to_i

            dest_ids[target_data['tenant']] ||= []
            dest_ids[target_data['tenant']] << dest_id

            dest_targets[dest_id] ||= []
            dest_targets[dest_id] << target
          end

          [dest_ids, dest_targets]
        end

        def api_load_has_one_send(dest_model, foreign_key, dest_ids, dest_targets)
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
      end
    end
  end
end
