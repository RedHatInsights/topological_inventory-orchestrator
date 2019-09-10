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

      SCHEDULED_EVENT_INTERVAL = 1.hour
      POLL_TIME = 10.seconds

      def self.run!(worker)
        manager = new(worker)
        manager.run!
      end

      def initialize(worker)
        self.worker = worker
        self.sync_semaphore = Mutex.new
        self.queue = Queue.new
      end

      def run!
        Thread.new { event_listener }
        Thread.new { scheduler }

        processor
      end

      private

      attr_accessor :queue, :sync_semaphore, :worker
      #
      # Event listener invokes sync when received event from Sources API
      #
      def event_listener
        messaging_client.subscribe_topic(subscribe_opts) do |message|
          if events.include?(message.message)
            queue.push(:event_name => message.message,
                       :model_id   => message.payload['id'])
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
                     :model_id   => nil)

          sleep(SCHEDULED_EVENT_INTERVAL)
        end
      end

      #
      # Processor starts sync once per 10 seconds
      #   if there is an event in the queue
      #
      def processor
        loop do
          events = []
          events << queue.pop until queue.empty?

          # Sources UI (through API) generates multiple events at the same time
          # One sync is sufficient
          if (event = events.first).present?
            process_event(event[:event_name], event[:model_id])
          end

          sleep(POLL_TIME)
        end
      end

      def process_event(event_name, model_id = nil)
        # Just one sync at the same time
        sync_semaphore.synchronize do
          msg = "Sync started by event #{event_name}: id [#{model_id.presence || '---'}]"
          logger.send(model_id.present? ? :info : :debug, msg) # Info log only for Sources API events
          worker.make_openshift_match_database
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
