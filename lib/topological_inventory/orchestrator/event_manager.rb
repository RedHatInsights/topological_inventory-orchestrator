module TopologicalInventory
  module Orchestrator
    # Event Manager subscribes to kafka topic "platform.sources.event-stream"
    # and listens to messages from Sources API: create/update/destroy
    # on models used for computing of digest (see Source#digest_values)
    #
    # When event is received then sync API -> OpenShift is invoked.
    # If no event is caught for >= 1 hour, sync is invoked too.
    class EventManager
      include Logging

      SYNC_EVENT_INTERVAL = 1.hour
      SKIP_SUBSEQUENT_EVENTS_DURATION = 5.seconds

      def self.run!(worker)
        manager = new(worker)
        manager.run!
      end

      def initialize(worker)
        self.worker = worker
        self.event_semaphore = Mutex.new
        self.sync_semaphore  = Mutex.new
        self.last_event_at = nil
        self.publisher_sleep_time = 0
      end

      def run!
        Thread.new { listener }
        loop { scheduled_sync }
      end

      private

      attr_accessor :event_semaphore, :last_event_at,
                    :publisher_sleep_time, :sync_semaphore, :worker

      def listener
        messaging_client.subscribe_topic(subscribe_opts) do |message|
          begin
            if events.include?(message.message)
              Thread.new { process_event(message.message, message.payload['id']) } # Ack message, don't wait
            end
          rescue => err
            logger.error("#{err}\n#{err.backtrace.join("\n")}")
          end
        end
      ensure
        messaging_client&.close
      end

      # Scheduled_sync invokes sync once per hour if no event came
      def scheduled_sync
        schedule_sync = false
        event_semaphore.synchronize do
          now = Time.now.utc
          # Schedule sync when orchestrator starts or if no event was received in last hour
          schedule_sync = last_event_at.nil? || (now - last_event_at > SYNC_EVENT_INTERVAL)

          # Set next sync to 1 hour from last sync
          self.publisher_sleep_time = if schedule_sync
                                        SYNC_EVENT_INTERVAL
                                      else
                                        [SYNC_EVENT_INTERVAL - (now - last_event_at), 1.second].max.to_i
                                      end
        end
        Thread.new { process_event("Scheduled.Sync") if schedule_sync }
        sleep(publisher_sleep_time)
      end

      # Sources UI (through API) generates multiple events
      # for one update, just 1 should be processed
      def process_event(event_name, model_id = nil)
        event_semaphore.synchronize do
          if last_event_at.nil? || (Time.now.utc - last_event_at > SKIP_SUBSEQUENT_EVENTS_DURATION)
            self.last_event_at = Time.now.utc
          else
            return
          end
        end

        sleep(SKIP_SUBSEQUENT_EVENTS_DURATION)

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
