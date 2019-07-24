require File.join(__dir__, "../lib/topological_inventory/orchestrator/metric_scaler")
require File.join(__dir__, "../lib/topological_inventory/orchestrator/metric_scaler/watcher")
require File.join(__dir__, "../lib/topological_inventory/orchestrator/object_manager")

describe TopologicalInventory::Orchestrator::MetricScaler do
  let(:instance) { described_class.new(logger) }
  let(:logger)   { Logger.new(StringIO.new).tap { |logger| allow(logger).to receive(:info) } }

  it "skips deployment configs that aren't fully configured" do
    deployment     = double("deployment", :metadata => double("metadata", :name => "deployment-#{rand(100..500)}", :annotations => {}))
    object_manager = double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment], :get_deployment_config => deployment)

    expect(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).twice.and_return(object_manager)
    expect(Thread).to receive(:new).and_yield # Sorry, The use of doubles or partial doubles from rspec-mocks outside of the per-test lifecycle is not supported. (RSpec::Mocks::OutsideOfExampleError)

    watcher = described_class::Watcher.new(deployment.metadata.name, logger)
    expect(watcher).not_to receive(:percent_usage_from_metrics)
    expect(described_class::Watcher).to receive(:new).with(deployment.metadata.name, logger).and_return(watcher)

    instance.run_once
  end
end
