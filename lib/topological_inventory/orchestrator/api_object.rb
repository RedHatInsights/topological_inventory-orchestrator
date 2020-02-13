module TopologicalInventory
  module Orchestrator
    class ApiObject
      include Logging

      delegate :[], :[]=, :to => :attributes

      attr_accessor :attributes

      def initialize(attributes)
        self.attributes = attributes
      end
    end
  end
end
