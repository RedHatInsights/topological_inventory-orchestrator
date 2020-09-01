require "topological_inventory/scheduler/worker"

RSpec.describe TopologicalInventory::Scheduler::Worker do
  subject { described_class.new }

  describe "#run" do
    it "loads tasks and invokes refresh" do
      expect(subject).to receive(:load_running_tasks).and_return([])
      expect(subject).to receive(:service_instance_refresh)

      subject.run
    end
  end

  describe "#load_running_tasks" do

  end
end
