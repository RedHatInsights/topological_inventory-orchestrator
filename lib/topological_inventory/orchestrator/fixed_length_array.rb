module TopologicalInventory
  module Orchestrator
    class FixedLengthArray
      attr_reader :max_size, :values

      def initialize(max_size)
        @max_size = max_size
        @values   = []
      end

      def <<(new_value)
        @values.tap { |a| a.pop if a.length == max_size }.unshift(new_value)
      end

      def average
        return nil if values.empty?

        values.sum / values.size
      end
    end
  end
end
