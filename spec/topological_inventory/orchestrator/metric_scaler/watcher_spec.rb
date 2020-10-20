require "topological_inventory/orchestrator/metric_scaler/watcher"
require "topological_inventory/orchestrator/object_manager"

describe TopologicalInventory::Orchestrator::MetricScaler::Watcher do
  let(:logger) { Logger.new(StringIO.new).tap { |logger| allow(logger).to receive(:info) } }

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

  context "configured" do
    let(:deployment)     { double("deployment", :metadata => double("metadata", :name => "deployment-#{rand(100..500)}", :annotations => annotations), :spec => double("spec", :replicas => replicas)) }
    let(:metrics)        { watcher.send(:metrics) }
    let(:object_manager) { double("TopologicalInventory::Orchestrator::ObjectManager", :get_deployment_configs => [deployment], :get_deployment_config => deployment) }
    let(:prometheus)     { double("TopologicalInventory::Orchestrator::Metrics::MetricsScaler") }
    let(:replicas)       { 2 }
    let(:watcher)        { described_class.new(prometheus, deployment, deployment.metadata.name, logger) }

    before { allow(TopologicalInventory::Orchestrator::ObjectManager).to receive(:new).and_return(object_manager) }

    describe "#desired_replicas" do
      it "with no usage data" do
        expect(watcher.send(:desired_replicas)).to eq(1)
      end

      it "low usage" do
        metrics << 0.0

        expect(watcher.send(:desired_replicas)).to eq(1)
      end

      it "level usage" do
        metrics << 50.0

        expect(watcher.send(:desired_replicas)).to eq(2)
      end

      it "high usage" do
        metrics << 80.0

        expect(watcher.send(:desired_replicas)).to eq(3)
      end

      context "at minimum replicas" do
        let(:replicas) { 1 }

        it "won't scale below the minimum" do
          metrics << 0.0

          expect(watcher.send(:desired_replicas)).to eq(1)
        end
      end

      context "at maximum replicas" do
        let(:replicas) { 5 }

        it "won't scale above the maximum" do
          metrics << 100.0

          expect(watcher.send(:desired_replicas)).to eq(5)
        end
      end
    end

    describe "#scale_to_desired_replicas" do
      it "no change necessary" do
        expect(watcher).to receive(:desired_replicas).and_return(2)

        expect(logger).not_to receive(:info).with("Scaling #{deployment.metadata.name} to 2 replicas")

        watcher.scale_to_desired_replicas
      end

      it "will scale down" do
        expect(watcher).to receive(:desired_replicas).and_return(1)

        expect(logger).to receive(:info).with("Scaling #{deployment.metadata.name} to 1 replicas")
        expect(object_manager).to receive(:scale).with(deployment.metadata.name, 1)
        subsets = [double("subset", :addresses => [{:ip => "192.0.2.0"}])]
        expect(object_manager).to receive(:get_endpoint).with(deployment.metadata.name).and_return(double("endpoint", :subsets => subsets))

        watcher.scale_to_desired_replicas
      end

      it "will scale down" do
        expect(watcher).to receive(:desired_replicas).and_return(3)

        expect(logger).to receive(:info).with("Scaling #{deployment.metadata.name} to 3 replicas")
        expect(object_manager).to receive(:scale).with(deployment.metadata.name, 3)
        subsets = [double("subset", :addresses => [{:ip => "192.0.2.0"}]), double("subset", :addresses => [{:ip => "192.0.2.1"}, {:ip => "192.0.2.2"}])]
        expect(object_manager).to receive(:get_endpoint).with(deployment.metadata.name).and_return(double("endpoint", :subsets => subsets))

        watcher.scale_to_desired_replicas
      end
    end
  end
end
