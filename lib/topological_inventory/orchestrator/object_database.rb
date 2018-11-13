module TopologicalInventory
  module Orchestrator
    class ObjectDatabase
      def initialize
        @database = {}
      end

      def add(object)
        digest(object).tap do |object_digest|
          @database[object_digest] = object
        end
      end

      def [](key)
        @database[key]
      end

      def digest(object)
        require 'digest'
        Digest::SHA1.hexdigest(Marshal.dump(object))
      end
    end
  end
end
