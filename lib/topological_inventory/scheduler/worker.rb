require 'manageiq-messaging'
require 'topological_inventory/orchestrator/logger'

module TopologicalInventory
  module Scheduler
    class Worker
      include TopologicalInventory::Orchestrator::Logging

      REFRESH_QUEUE_NAME = 'platform.topological-inventory.collector-ansible-tower'.freeze

      def initialize(opts = {})
        messaging_client_opts = opts.select { |k, _| %i[host port].include?(k) }
        self.messaging_client_opts = default_messaging_opts.merge(messaging_client_opts)
      end

      def run
        logger.info('Topological Inventory Refresh Scheduler started...')

        tasks = load_running_tasks
        service_instance_refresh(tasks)

        logger.info('Topological Inventory Refresh Scheduler finished...')
      end

      private

      attr_accessor :messaging_client_opts

      def service_instance_refresh(tasks)
        logger.info('ServiceInstance#refresh - Started')
        payload = {}

        tasks.each do |task|
          # grouping requests by Source
          # - tasks are ordered by source_id
          if payload[:source_id].present? && payload[:source_id] != task.source_id
            send_payload(payload)
            payload = {}
          end

          log_with(task.forwardable_headers['x-rh-insights-request-id']) do
            logger.info("ServiceInstance#refresh - Task(id: #{task.id}), ServiceInstance(source_ref: #{task.target_source_ref}), Source(id: #{task.source_id}")

            payload[:source_id]  = task.source_id.to_s
            payload[:source_uid] = task.source_uid.to_s

            payload[:params] ||= []
            payload[:params] << {
              :request_context => task.forwardable_headers,
              :source_ref      => task.target_source_ref,
              :task_id         => task.id.to_s
            }
          end
        end

        # sending remaining data
        send_payload(payload) if payload[:params].present?
      rescue => e
        logger.error("ServiceInstance#refresh - Failed. Task(id: #{tasks_id(tasks).join(' | ')}). Error: #{e.message}, #{e.backtrace.join('\n')}")
      end

      # TODO: restrict targeted refreshes to AnsibleTower Source
      # Not needed now as we don't have service_instance tasks not belonging to Tower
      def load_running_tasks
        Task.where(:state => 'running', :target_type => 'ServiceInstance')
            .joins(:source)
            .select('tasks.id, tasks.source_id, tasks.target_source_ref, tasks.forwardable_headers, sources.uid as source_uid')
            .order('source_id')
      end

      def tasks_id(tasks = load_running_tasks)
        tasks.pluck(:id)
      end

      def send_payload(payload)
        logger.info("ServiceInstance#refresh - publishing to kafka: Source(id: #{payload[:source_id]})...")
        messaging_client.publish_topic(
          :service => REFRESH_QUEUE_NAME,
          :event   => 'ServiceInstance.refresh',
          :payload => payload.to_json
        )
        logger.info("ServiceInstance#refresh - publishing to kafka: Source(id: #{payload[:source_id]})...Complete")
      end

      def messaging_client
        @messaging_client ||= ManageIQ::Messaging::Client.open(messaging_client_opts)
      end

      def default_messaging_opts
        {
          :encoding => 'json',
          :protocol => :Kafka
        }
      end
    end
  end
end

