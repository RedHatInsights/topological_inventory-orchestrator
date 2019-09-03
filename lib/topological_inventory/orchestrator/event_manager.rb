module TopologicalInventory
  module Orchestrator
    class EventManager
      include Logging

      ORCHESTRATOR_EVENT_NAME = "Orchestrator.sync".freeze
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
        loop { publisher }
      end

      private

      attr_accessor :event_semaphore, :last_event_at,
                    :publisher_sleep_time, :sync_semaphore, :worker

      def listener
        messaging_client.subscribe_topic(subscribe_opts) do |message|
          begin
            if events.include?(message.message)
              Thread.new { process_event } # Ack message, don't wait
            end
          rescue => err
            logger.error("#{err} | #{err.backtrace.join("\n")}")
          end
        end
      ensure
        messaging_client&.close
      end

      # Publisher invokes sync event once per hour if no other event came
      def publisher
        event_semaphore.synchronize do
          self.publisher_sleep_time = if last_event_at.nil? || (Time.now.utc - last_event_at > SYNC_EVENT_INTERVAL)
                                        publish_sync_event
                                        SYNC_EVENT_INTERVAL + 5.seconds # 5 seconds for kafka delivery delay
                                      else
                                        [SYNC_EVENT_INTERVAL - (Time.now.utc - last_event_at).to_i, 0].max
                                      end
        end
        sleep(publisher_sleep_time)
      end

      # Sources UI (through API) generates multiple events
      # for one update, just 1 should be processed
      def process_event
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
        return @events if @events.present?

        @events = %w[Source Endpoint Authentication Application].collect do |model|
          %W[#{model}.create #{model}.update #{model}.destroy]
        end.flatten
        @events << ORCHESTRATOR_EVENT_NAME
        @events
      end

      def publish_sync_event
        publish_opts = {
          :service => queue_name,
          :event   => ORCHESTRATOR_EVENT_NAME,
          :payload => {}.to_json
        }

        messaging_client.publish_topic(publish_opts)
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
