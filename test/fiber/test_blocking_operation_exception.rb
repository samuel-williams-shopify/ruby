# frozen_string_literal: true

# Test that rb_fiber_scheduler_blocking_operation_wait correctly handles
# exceptions raised by the scheduler's blocking_operation_wait method.
#
# When the scheduler raises (e.g. due to fiber interrupt), the exception
# propagates through rb_funcall in the C function, bypassing the cleanup
# code that nulls out operation->function, operation->state, etc.
# operation->state points to a stack-allocated struct in the caller
# (rb_nogvl), so after the exception unwinds that frame the pointer is
# dangling. Any subsequent dereference — including from dfree during GC
# or a re-execution of the operation — causes a segfault.

require "test/unit"
require_relative "scheduler"

class TestBlockingOperationException < Test::Unit::TestCase
  # Scheduler whose blocking_operation_wait raises after completing the work,
  # simulating a fiber interrupt arriving after the operation finishes.
  class InterruptingScheduler < Scheduler
    def blocking_operation_wait(blocking_operation)
      super
      raise Interrupt, "simulated fiber interrupt"
    end
  end

  def test_blocking_operation_exception_does_not_corrupt_state
    skip "IO::Buffer not available" unless defined?(IO::Buffer)

    # Use a buffer large enough to trigger the scheduler's blocking_operation_wait
    # (rb_nogvl calls the scheduler hook for large copies).
    size   = 2 * 1024 * 1024  # 2 MiB
    source = IO::Buffer.new(size)
    dest   = IO::Buffer.new(size)
    source.clear(65) # fill with 'A'

    caught = []

    Thread.new do
      Fiber.set_scheduler(InterruptingScheduler.new)

      Fiber.schedule do
        dest.copy(source, 0, size, 0)
      rescue Interrupt => e
        caught << e
      end
    end.join

    assert_equal 1, caught.size, "Expected exactly one Interrupt to be rescued"

    # Trigger GC to detect any use-after-free via the stale operation->state
    # pointer. Without the fix, the dfree for the blocking_operation TypedData
    # can dereference a now-invalid stack pointer, causing a segfault here or
    # silently corrupting a subsequent allocation.
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact if GC.respond_to?(:compact)

    # If we reach here without crashing, the fix is working.
    assert_equal size, dest.size
  end
end
