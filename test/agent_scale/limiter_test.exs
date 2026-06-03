defmodule AgentScale.LimiterTest do
  use ExUnit.Case, async: false

  setup do
    # Reset limiter to known state before each test
    AgentScale.Limiter.reset(4)
    :ok
  end

  describe "request/1 and release/1" do
    test "grants slot immediately when available" do
      AgentScale.Limiter.request(self())
      assert_receive {:agent_scale_slot, ref} when is_reference(ref), 100
    end

    test "queues requests when no slots available" do
      AgentScale.Limiter.reset(1)

      # Take the only slot
      AgentScale.Limiter.request(self())
      assert_receive {:agent_scale_slot, ref1}, 100

      # This should queue
      AgentScale.Limiter.request(self())
      refute_receive {:agent_scale_slot, _}, 50

      # Release and the queued request should be granted
      AgentScale.Limiter.release(ref1)
      assert_receive {:agent_scale_slot, _ref2}, 100
    end

    test "reclaims slot when holder dies" do
      AgentScale.Limiter.reset(1)

      # Spawn a process that takes a slot then dies
      holder =
        spawn(fn ->
          AgentScale.Limiter.request(self())
          receive do: (:die -> :ok)
        end)

      Process.sleep(50)

      # Our request should queue
      AgentScale.Limiter.request(self())
      refute_receive {:agent_scale_slot, _}, 50

      # Kill the holder
      send(holder, :die)
      Process.sleep(50)

      # Now we should get the slot
      assert_receive {:agent_scale_slot, _}, 100
    end
  end

  describe "reset/1" do
    test "changes max slots" do
      AgentScale.Limiter.reset(2)

      AgentScale.Limiter.request(self())
      AgentScale.Limiter.request(self())
      assert_receive {:agent_scale_slot, _}, 100
      assert_receive {:agent_scale_slot, _}, 100

      # Third request should queue
      AgentScale.Limiter.request(self())
      refute_receive {:agent_scale_slot, _}, 50
    end
  end
end
