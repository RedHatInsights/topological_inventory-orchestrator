module TopologicalInventory
  module Orchestrator
    class OpenshiftObject
      include Logging

      attr_writer :openshift_object

      delegate :metrics, :to => :object_manager

      def initialize(object_manager, openshift_object = nil)
        self.object_manager = object_manager
        self.openshift_object = openshift_object
      end

      def openshift_object(reload: false)
        return @openshift_object if @openshift_object.present? && !reload

        @openshift_object = load_openshift_object
      end

      def uid
        raise NotImplementedError, "#{__method__} must be implemented in a subclass"
      end

      private

      def load_openshift_object
        raise NotImplementedError, "#{__method__} must be implemented in a subclass"
      end

      attr_accessor :object_manager
    end
  end
end
