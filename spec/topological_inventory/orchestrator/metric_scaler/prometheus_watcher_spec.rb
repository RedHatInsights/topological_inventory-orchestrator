require "topological_inventory/orchestrator/metric_scaler/prometheus_watcher"
require "topological_inventory/orchestrator/test_models/object_manager"

describe TopologicalInventory::Orchestrator::MetricScaler::PrometheusWatcher do
  let(:logger) { Logger.new(StringIO.new).tap { |logger| allow(logger).to receive(:info) } }

  let(:annotations) do
    {
      "metric_scaler_max_replicas"        => "10",
      "metric_scaler_min_replicas"        => "1",
      "metric_scaler_target_usage"        => "1",
      "metric_scaler_scale_threshold"     => ".5",
    }
  end

  let(:deployment_config_name) { 'topological-inventory-persister' }
  let(:deployment)     { double("deployment", :metadata => double("metadata", :name => deployment_config_name, :annotations => annotations), :spec => double("spec", :replicas => replicas)) }
  let(:metrics)        { watcher.send(:metrics) }
  let(:prometheus)     { double }
  let(:object_manager) { double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment], :get_deployment_config => deployment) }
  let(:replicas)       { 3 }
  let(:watcher)        { described_class.new(prometheus, deployment, deployment.metadata.name, 'prometheus.mnm-ci', logger) }

  before { allow(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager) }

  context "downloading metrics" do
    before do
      stub_const("#{described_class}::METRICS_CHECK_INTERVAL", 0)

      # Allow just a single run
      allow(watcher).to receive(:finished?) do
        finished = watcher.instance_variable_get(:@finished)
        old_value = finished.value
        finished.value = true
        old_value
      end
    end

    it "fills metrics array when successful" do
      downloaded = [nil, [nil, Array.new(10) { [Time.now.to_i, 10] }]]
      allow(watcher).to receive(:download_metrics).and_return(downloaded)

      watcher.start
      watcher.thread.join

      expect(metrics.values).to eq(Array.new(10, 10))
    end

    it "allows scaling run only when successful" do
      downloaded = [nil, [nil, Array.new(5) { [Time.now.to_i, 10] }]]
      allow(watcher).to receive(:download_metrics).and_return(downloaded)

      watcher.start
      watcher.thread.join

      expect(metrics.average).to eq(10)
      expect(watcher.scaling_allowed?).to be_truthy
    end

    it "doesn't allow scaling run when no data collected" do
      allow(watcher).to receive(:download_metrics).and_return([])

      watcher.start
      watcher.thread.join

      expect(watcher.scaling_allowed?).to be_falsey
    end

    it "doesn't allow scaling run when zero data collected" do
      downloaded = [nil, [nil, Array.new(10) { [Time.now.to_i, 0] }]]
      allow(watcher).to receive(:download_metrics).and_return(downloaded)

      watcher.start
      watcher.thread.join

      expect(metrics.values).to eq(Array.new(10, 0))
      expect(watcher.scaling_allowed?).to be_falsey
    end
  end

  context "scaling" do
    before do
      watcher.instance_variable_set(:@target_usage, 10)
      watcher.instance_variable_set(:@scale_threshold, 5)
    end

    it "doesn't scale if no data available" do
      expect(watcher.send(:desired_replicas)).to eq(replicas)

      10.times { metrics << 0 }
      expect(watcher.send(:desired_replicas)).to eq(replicas)
    end

    it "scales up when kafka consumer lag is greater than threshold" do
      10.times { metrics << 16 }

      expect(watcher.send(:desired_replicas)).to eq(replicas + 1)
    end

    it "doesn't scale up when limit reached" do
      allow(deployment.spec).to receive(:replicas).and_return(10)

      10.times { metrics << 16 }
      expect(watcher.send(:desired_replicas)).to eq(10)
    end

    it "scales down when kafka consumer lag is lower than threshold" do
      10.times { metrics << 4 }
      expect(watcher.send(:desired_replicas)).to eq(replicas - 1)
    end

    it "doesn't scale below 1" do
      allow(deployment.spec).to receive(:replicas).and_return(1)

      10.times { metrics << 1 }
      expect(watcher.send(:desired_replicas)).to eq(1)
    end

    it "doesn't scale when kafka consumer lag is in limits" do
      10.times { metrics << 11 }
      expect(watcher.send(:desired_replicas)).to eq(replicas)
    end
  end

  context "when prometheus is down" do
    before do
      stub_const("#{described_class}::METRICS_CHECK_INTERVAL", 0)
      allow(watcher).to receive(:finished?) do
        finished = watcher.instance_variable_get(:@finished)
        old_value = finished.value
        finished.value = true
        old_value
      end

      allow(watcher).to receive(:promql_query).and_return("")
      allow(RestClient).to receive(:get).and_raise(RestClient::ExceptionWithResponse)
    end

    it "logs a metric" do
      expect(prometheus).to receive(:record_error).once

      watcher.start
      watcher.thread.join

      expect(watcher.scaling_allowed?).to be_falsey
    end
  end
end
