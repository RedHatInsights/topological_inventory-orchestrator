module TopologicalInventory
  module Orchestrator
    # Event Manager subscribes to kafka topic "platform.sources.event-stream"
    # and listens to messages from Sources API: create/update/destroy
    # on models used for computing of digest (see Source#digest_values)
    #
    # When event is received then sync API -> OpenShift is invoked.
    # Sync is invoked also once per hour
    class EventManager
      include Logging

      def self.run!(worker)
        manager = new(worker)
        manager.run!
      end

      def initialize(worker)
        self.worker = worker
        self.queue = Queue.new
      end

      def run!
        Thread.new { event_listener }
        Thread.new { scheduler }

        processor
      end

      private

      attr_accessor :queue, :worker
      #
      # Event listener invokes sync when received event from Sources API
      #
      def event_listener
        messaging_client.subscribe_topic(subscribe_opts) do |message|
          if events.include?(message.message)
            queue.push(:event_name => message.message,
                       :model   => message.payload)
          end
        end
      ensure
        messaging_client&.close
      end

      #
      # Scheduler invokes sync once per hour
      #
      def scheduler
        loop do
          queue.push(:event_name => "Scheduled.Sync",
                     :model   => nil)

          sleep((::Settings.sync.scheduled_event_hours || 1).hours)
        end
      end

      #
      # Processor starts sync once per 10 seconds
      #   if there is an event in the queue
      #
      def processor
        loop do
          events = []
          # TODO: split to batches for big queues
          events << queue.pop until queue.empty?

          if events.present?
            process_events(events)
          end

          sleep((::Settings.sync.poll_time_seconds || 10).seconds)
        end
      end

      # If there is full sync event, skip all targeted events
      def process_events(events)
        updater = TargetedUpdate.new(worker)

        full_sync = false

        events.each do |event|
          if event[:event_name] == 'Scheduled.Sync'
            full_sync = true
            break
          end
          model, action = event[:event_name].split('.')
          updater.add_target(model, action, event[:model])
        end

        if full_sync
          updater = nil # For Garbage collector
          worker.make_openshift_match_database
        else
          updater.sync_targets_with_openshift
        end
      end

      def persist_ref
        "topological-inventory-orchestrator"
      end

      def queue_name
        "platform.sources.event-stream"
      end

      # Orchestrator is listening to these events
      # (digest is created from these models)
      def events
        @events ||= %w[Source Endpoint Authentication Application].collect do |model|
          %W[#{model}.create #{model}.update #{model}.destroy]
        end.flatten
      end

      def messaging_client
        @messaging_client ||= ManageIQ::Messaging::Client.open(
          :protocol    => :Kafka,
          :host        => ENV["QUEUE_HOST"] || "localhost",
          :port        => ENV["QUEUE_PORT"] || "9092",
          :group_ref   => persist_ref,
          :persist_ref => persist_ref,
          :encoding    => "json"
        )
      end

      def subscribe_opts
        {
          :persist_ref     => persist_ref,
          :service         => queue_name,
          :session_timeout => 60 # seconds
        }
      end
    end
  end
end
