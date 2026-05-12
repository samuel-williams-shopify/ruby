require_relative '../../spec_helper'

ruby_version_is "4.1" do
  describe "Fiber#quantum" do
    it "returns an Integer" do
      f = Fiber.new { Fiber.yield }
      f.quantum.should be_kind_of(Integer)
    end

    it "returns a positive default" do
      f = Fiber.new { Fiber.yield }
      f.quantum.should > 0
    end

    it "can be set via Fiber.new(quantum:)" do
      f = Fiber.new(quantum: 10_000, blocking: false) { Fiber.yield }
      f.quantum.should == 10_000
    end

    it "can be set via #quantum=" do
      f = Fiber.new { Fiber.yield }
      f.quantum = 25_000
      f.quantum.should == 25_000
    end

    it "raises ArgumentError when initialized with non-positive values" do
      -> { Fiber.new(quantum: 0) { Fiber.yield } }.should raise_error(ArgumentError)
      -> { Fiber.new(quantum: -1) { Fiber.yield } }.should raise_error(ArgumentError)
    end

    it "raises ArgumentError when set to non-positive values" do
      f = Fiber.new { Fiber.yield }
      -> { f.quantum = 0 }.should raise_error(ArgumentError)
      -> { f.quantum = -1 }.should raise_error(ArgumentError)
    end

    it "raises TypeError when initialized with a non-integer" do
      -> { Fiber.new(quantum: 1.5) { Fiber.yield } }.should raise_error(TypeError)
    end

    it "raises TypeError when set to a non-numeric" do
      f = Fiber.new { Fiber.yield }
      -> { f.quantum = :big }.should raise_error(TypeError)
      -> { f.quantum = nil }.should raise_error(TypeError)
      -> { f.quantum = 1.5 }.should raise_error(TypeError)
    end

    it "raises TypeError when set to a symbol" do
      f = Fiber.new { Fiber.yield }
      -> { f.quantum = :large }.should raise_error(TypeError)
    end

    it "raises RangeError when initialized or set beyond the uint32 range" do
      f = Fiber.new { Fiber.yield }

      -> { Fiber.new(quantum: 2**32) { Fiber.yield } }.should raise_error(RangeError)
      -> { f.quantum = 2**32 }.should raise_error(RangeError)
    end

    it "controls the runtime value at forced preemption" do
      # A fiber with a small quantum accumulates less runtime per slot than
      # one with a large quantum. Without a scheduler, we verify the quantum
      # is stored and returned correctly — behavioral preemption testing requires
      # a scheduler and is covered by TestFiber#test_fiber_preemption_interleaves_fibers.
      small_q = Fiber.new(quantum: 5_000) { Fiber.yield }
      large_q = Fiber.new(quantum: 200_000) { Fiber.yield }

      small_q.quantum.should == 5_000
      large_q.quantum.should == 200_000
      small_q.quantum.should < large_q.quantum
    end
  end
end
