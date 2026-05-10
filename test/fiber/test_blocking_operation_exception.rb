# frozen_string_literal: true

# Test that rb_fiber_scheduler_blocking_operation_wait correctly handles
# exceptions raised by the scheduler's blocking_operation_wait method.
#
# When blocking_operation_wait raises, rb_funcall propagates the exception,
# bypassing the cleanup code that nulls out operation->function/state/data.
# operation->state points to a stack-allocated struct in the caller (rb_nogvl),
# so after the exception unwinds that caller's frame the pointer is dangling.
# Any subsequent dereference of those fields (e.g. from a scheduler that
# tracks and cancels blocking operations during io_close) causes a segfault.

require "test/unit"
require_relative "scheduler"

class TestBlockingOperationException < Test::Unit::TestCase
  # Scheduler that raises immediately from blocking_operation_wait without
  # executing the operation — the simplest possible trigger for the bug.
  class RaisingScheduler < Scheduler
    def blocking_operation_wait(blocking_operation)
      raise Interrupt, "simulated fiber interrupt"
    end
  end

  def test_blocking_operation_wait_exception
    skip "IO::Buffer not available" unless defined?(IO::Buffer)

    size   = 2 * 1024 * 1024  # 2 MiB — triggers the scheduler hook via rb_nogvl
    source = IO::Buffer.new(size)
    dest   = IO::Buffer.new(size)
    source.clear(65)

    caught = []

    Thread.new do
      Fiber.set_scheduler(RaisingScheduler.new)
      Fiber.schedule do
        dest.copy(source, 0, size, 0)
      rescue Interrupt => e
        caught << e
      end
    end.join

    assert_equal 1, caught.size, "Expected the Interrupt to propagate to Ruby"

    # Force GC to run dfree on the blocking_operation TypedData.
    # With ASAN or a scheduler that dereferences operation->state during
    # cleanup (e.g. io-event's io_close), this is where the crash manifests.
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact if GC.respond_to?(:compact)
  end
end
