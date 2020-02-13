module TopologicalInventory
  module Orchestrator
    def self.root
      require 'pathname'
      Pathname.new(__dir__).join("..")
    end
  end
end

require "topological_inventory/orchestrator/worker"
require "topological_inventory/orchestrator/targeted_update"
