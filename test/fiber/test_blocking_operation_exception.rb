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

  # Reproduce the tcp_socket.rb pattern: a blocking IO operation (large
  # IO::Buffer copy) raises through the scheduler, then we close a socket.
  # If the exception corrupted scheduler state, server.close may crash.
  def test_blocking_operation_exception_with_socket_close
    skip "IO::Buffer not available" unless defined?(IO::Buffer)

    size   = 2 * 1024 * 1024  # 2 MiB — large enough to trigger blocking_operation_wait
    source = IO::Buffer.new(size)
    dest   = IO::Buffer.new(size)
    source.clear(65) # fill with 'A'

    server = TCPServer.new("127.0.0.1", 0)
    caught = []

    # Run the blocking operation that raises inside a scheduled thread
    Thread.new do
      Fiber.set_scheduler(InterruptingScheduler.new)
      Fiber.schedule do
        dest.copy(source, 0, size, 0)
      rescue Interrupt => e
        caught << e
      end
    end.join

    assert_equal 1, caught.size, "Expected exactly one Interrupt"

    # After the exception propagated through rb_fiber_scheduler_blocking_operation_wait,
    # operation->state is a dangling pointer. Trigger GC and then close a socket:
    # if the dangling pointer is somehow dereferenced during these operations,
    # ASAN/valgrind/the OS will detect it.
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact if GC.respond_to?(:compact)

    server.close  # mirrors tcp_socket.rb:48

    assert_equal size, dest.size
  ensure
    server&.close rescue nil
  end

  def test_blocking_operation_exception_does_not_corrupt_state
    skip "IO::Buffer not available" unless defined?(IO::Buffer)

    size   = 2 * 1024 * 1024
    source = IO::Buffer.new(size)
    dest   = IO::Buffer.new(size)
    source.clear(65)

    caught = []

    Thread.new do
      Fiber.set_scheduler(InterruptingScheduler.new)
      Fiber.schedule do
        dest.copy(source, 0, size, 0)
      rescue Interrupt => e
        caught << e
      end
    end.join

    assert_equal 1, caught.size
    GC.start(full_mark: true, immediate_sweep: true)
    GC.compact if GC.respond_to?(:compact)
    assert_equal size, dest.size
  end
end
