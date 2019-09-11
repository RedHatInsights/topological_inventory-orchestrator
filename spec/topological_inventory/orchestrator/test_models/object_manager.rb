require_relative "kube_client"

module TopologicalInventory
  module Orchestrator
    module TestModels
      class ObjectManager < TopologicalInventory::Orchestrator::ObjectManager
        def self.available?
          true
        end

        def initialize(kube_connection = nil)
          @kube_connection = kube_connection
        end

        def connection
          kube_connection
        end

        def kube_connection
          @kube_connection ||= TopologicalInventory::Orchestrator::TestModels::KubeClient
        end

        def check_deployment_config_quota(definition)
          # Noop
        end
      end
    end
  end
end
