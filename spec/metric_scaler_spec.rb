require File.join(__dir__, "../lib/topological_inventory/orchestrator/metric_scaler")
require File.join(__dir__, "../lib/topological_inventory/orchestrator/object_manager")

describe TopologicalInventory::Orchestrator::MetricScaler do
  let(:instance) { described_class.new(logger) }
  let(:logger)   { Logger.new(StringIO.new).tap { |logger| allow(logger).to receive(:info) } }

  let(:annotations) do
    {
      "metric_scaler_current_metric_name" => "topological_inventory_api_puma_busy_threads",
      "metric_scaler_max_metric_name"     => "topological_inventory_api_puma_max_threads",
      "metric_scaler_max_replicas"        => "5",
      "metric_scaler_min_replicas"        => "1",
      "metric_scaler_target_usage_pct"    => "50",
      "metric_scaler_scale_threshold_pct" => "20",
    }
  end

  def rest_client_response(busy, max)
    <<~EOS
      # HELP some help text
      # TYPE Some other description

      topological_inventory_api_puma_busy_threads #{busy}
      topological_inventory_api_puma_max_threads #{max}
    EOS
  end

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

  it "skips when no changes need to be made" do
    deployment     = double("deployment", :metadata => double("metadata", :name => "deployment", :annotations => annotations), :spec => double("spec", :replicas => 1))
    endpoint       = double("endpoint", :subsets => [double("subset", :addresses => [{:ip => "192.0.2.1"}])])
    object_manager = double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment])
    expect(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager)

    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Starting...")
    expect(object_manager).to receive(:get_endpoint).with(deployment.metadata.name).and_return(endpoint)
    expect(logger).to receive(:info).with("Metrics scaling enabled for #{deployment.metadata.name}")
    expect(RestClient).to receive(:get).with("http://192.0.2.1:9394/metrics").and_return(rest_client_response(1, 5))
    expect(logger).to receive(:info).with("Fetching configuration for deployment")
    expect(logger).to receive(:info).with("deployment consuming 1.0 of 5.0, 20.0%")
    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Complete")

    instance.run_once
  end

  it "scales up when necessary" do
    deployment     = double("deployment", :metadata => double("metadata", :name => "deployment", :annotations => annotations), :spec => double("spec", :replicas => 1))
    endpoint       = double("endpoint", :subsets => [double("subset", :addresses => [{:ip => "192.0.2.1"}])])
    object_manager = double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment])
    expect(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager)

    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Starting...")
    expect(object_manager).to receive(:get_endpoint).with(deployment.metadata.name).and_return(endpoint)
    expect(logger).to receive(:info).with("Metrics scaling enabled for #{deployment.metadata.name}")
    expect(RestClient).to receive(:get).with("http://192.0.2.1:9394/metrics").and_return(rest_client_response(4, 5))
    expect(logger).to receive(:info).with("deployment consuming 4.0 of 5.0, 80.0%")
    expect(object_manager).to receive(:scale).with(deployment.metadata.name, 2).once
    expect(logger).to receive(:info).with("Scaling deployment to 2 replicas")
    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Complete")

    instance.run_once
  end

  it "scales down when necessary" do
    deployment     = double("deployment", :metadata => double("metadata", :name => "deployment", :annotations => annotations), :spec => double("spec", :replicas => 2))
    endpoint       = double("endpoint", :subsets => [double("subset", :addresses => [{:ip => "192.0.2.1"}, {:ip => "192.0.2.2"}])])
    object_manager = double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment])
    expect(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager)

    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Starting...")
    expect(object_manager).to receive(:get_endpoint).with(deployment.metadata.name).and_return(endpoint)
    expect(logger).to receive(:info).with("Metrics scaling enabled for #{deployment.metadata.name}")
    expect(RestClient).to receive(:get).with("http://192.0.2.1:9394/metrics").and_return(rest_client_response(1, 5))
    expect(RestClient).to receive(:get).with("http://192.0.2.2:9394/metrics").and_return(rest_client_response(1, 5))
    expect(logger).to receive(:info).with("deployment consuming 2.0 of 10.0, 20.0%")
    expect(object_manager).to receive(:scale).with(deployment.metadata.name, 1).once
    expect(logger).to receive(:info).with("Scaling deployment to 1 replicas")
    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Complete")

    instance.run_once
  end

  it "won't scale below the minimum" do
    deployment     = double("deployment", :metadata => double("metadata", :name => "deployment", :annotations => annotations.merge("metric_scaler_min_replicas" => 2)), :spec => double("spec", :replicas => 2))
    endpoint       = double("endpoint", :subsets => [double("subset", :addresses => [{:ip => "192.0.2.1"}, {:ip => "192.0.2.2"}])])
    object_manager = double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment])
    expect(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager)

    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Starting...")
    expect(object_manager).to receive(:get_endpoint).with(deployment.metadata.name).and_return(endpoint)
    expect(logger).to receive(:info).with("Metrics scaling enabled for #{deployment.metadata.name}")
    expect(RestClient).to receive(:get).with("http://192.0.2.1:9394/metrics").and_return(rest_client_response(0, 5))
    expect(RestClient).to receive(:get).with("http://192.0.2.2:9394/metrics").and_return(rest_client_response(0, 5))
    expect(logger).to receive(:info).with("deployment consuming 0.0 of 10.0, 0.0%")
    expect(object_manager).not_to receive(:scale)
    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Complete")

    instance.run_once
  end

  it "won't scale above the maximum" do
    deployment     = double("deployment", :metadata => double("metadata", :name => "deployment", :annotations => annotations.merge("metric_scaler_max_replicas" => 2)), :spec => double("spec", :replicas => 2))
    endpoint       = double("endpoint", :subsets => [double("subset", :addresses => [{:ip => "192.0.2.1"}, {:ip => "192.0.2.2"}])])
    object_manager = double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment])
    expect(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager)

    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Starting...")
    expect(object_manager).to receive(:get_endpoint).with(deployment.metadata.name).and_return(endpoint)
    expect(logger).to receive(:info).with("Metrics scaling enabled for #{deployment.metadata.name}")
    expect(RestClient).to receive(:get).with("http://192.0.2.1:9394/metrics").and_return(rest_client_response(5, 5))
    expect(RestClient).to receive(:get).with("http://192.0.2.2:9394/metrics").and_return(rest_client_response(5, 5))
    expect(logger).to receive(:info).with("deployment consuming 10.0 of 10.0, 100.0%")
    expect(object_manager).not_to receive(:scale)
    expect(logger).to receive(:info).with("TopologicalInventory::Orchestrator::MetricScaler#run_once Complete")

    instance.run_once
  end
end
