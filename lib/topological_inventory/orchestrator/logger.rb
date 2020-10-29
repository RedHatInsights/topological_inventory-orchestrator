require "manageiq/loggers"

module TopologicalInventory
  module Orchestrator
    class << self
      attr_writer :logger
    end

    def self.logger
      @logger ||= ManageIQ::Loggers::CloudWatch.new.tap { |log| log.level = ENV['LOG_LEVEL'] || "INFO" }
    end

    module Logging
      def logger
        TopologicalInventory::Orchestrator.logger
      end
    end
  end
end
