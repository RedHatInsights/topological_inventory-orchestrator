require_relative "kube_resource"

module TopologicalInventory
  module Orchestrator
    module TestModels
      # This class is intended as mock openshift storage
      class KubeClient
        attr_accessor :config_maps, :deployment_configs,
                      :secrets, :endpoints,
                      :replication_controllers,
                      :pods
        # {
        #   name => [RecursiveOpenStruct*]
        # }*
        def initialize
          self.config_maps = {}
          self.deployment_configs = {}
          self.secrets = {}
          self.endpoints = {}
          self.replication_controllers = {}
          self.pods = {}
        end

        def get_config_maps(label_selector:, namespace:)
          find_by_label(config_maps, label_selector)
        end

        def get_deployment_configs(label_selector:, namespace:)
          find_by_label(deployment_configs, label_selector)
        end

        def get_replication_controllers(label_selector:, namespace:)
          find_by_label(replication_controllers, label_selector)
        end

        def get_secrets(label_selector:, namespace:)
          find_by_label(secrets, label_selector)
        end

        def get_deployment_config(name, _namespace)
          deployment_configs[name]
        end

        def get_endpoint(name, _namespace)
          endpoints[name]
        end

        def create_config_map(definition)
          add_definition(config_maps, definition)
        end

        def create_deployment_config(definition)
          add_definition(deployment_configs, definition)
        end

        def create_secret(definition)
          add_definition(secrets, definition)
        end

        # Noop, _map was updated outside
        def update_config_map(map)
          add_definition(config_maps, map.to_h)
        end

        # Noop, _secret was updated outside
        def update_secret(secret)
          add_definition(secrets, secret.to_h)
        end

        # Now only for scaling, skipped
        def patch_deployment_config(_name, _changes_hash, _namespace)
          nil
        end

        def delete_config_map(name, _namespace)
          config_maps.delete(name)
        end

        def delete_deployment_config(name, _namespace, delete_options:)
          deployment_configs.delete(name)
        end

        def delete_secret(name, _namespace)
          secrets.delete(name)
        end

        def get_pods(_namespace:, label_selector:)
          find_by_label(pods, label_selector)
        end

        private

        # Collection is in format
        # {
        #   (name => RecursiveOpenStruct)*
        # }
        def find_by_label(collection, label_selector)
          out = []

          label_key_value = label_selector.split("=")

          collection.each_value do |struct|
            struct.metadata.labels.to_h.each_pair do |label_name, label_value|
              if label_key_value.size == 2
                if label_key_value[0].to_sym == label_name && label_key_value[1] == label_value
                  out << struct
                end
              else
                out << struct if label_selector.to_sym == label_name
              end
            end
          end

          out
        end

        def add_definition(collection, hash)
          raise "Missing name when adding! #{hash[:metadata].inspect}" if hash[:metadata][:name].blank?

          collection[hash[:metadata][:name]] = TopologicalInventory::Orchestrator::TestModels::KubeResource.new(hash)
        end
      end
    end
  end
end
