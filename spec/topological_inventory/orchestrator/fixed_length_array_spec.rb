require File.join(__dir__, "../../../lib/topological_inventory/orchestrator/fixed_length_array")

describe TopologicalInventory::Orchestrator::FixedLengthArray do
  subject { described_class.new(5) }

  context "#average" do
    it "with fewer inserts than the max size" do
      2.times { subject << 2 }

      expect(subject.average).to eq(2)
    end

    it "with more inserts than the max size" do
      5.times { subject << 2 }
      5.times { subject << 4 }

      expect(subject.average).to eq(4)
    end
  end
end
