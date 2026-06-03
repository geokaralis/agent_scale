defmodule AgentScaleTest do
  use ExUnit.Case, async: true

  describe "run/1" do
    test "starts a run and returns session_id" do
      assert {:ok, session_id} = AgentScale.run()
      assert is_binary(session_id)
    end

    test "uses provided session_id" do
      session_id = "test-session-123"
      assert {:ok, ^session_id} = AgentScale.run(session_id: session_id)
    end

    test "emits events to subscribers" do
      # Subscribe before starting so we catch all events
      session_id = "test-events-#{System.unique_integer()}"
      AgentScale.subscribe(session_id)

      {:ok, ^session_id} =
        AgentScale.run(
          session_id: session_id,
          worker: AgentScale.Worker.Fake,
          request: %{steps: 2, delay: 10}
        )

      assert_receive {:agent_scale, ^session_id, {:run_started, %{}}}, 1000
      assert_receive {:agent_scale, ^session_id, {:step, %{n: 1, total: 2}}}, 1000
      assert_receive {:agent_scale, ^session_id, {:step, %{n: 2, total: 2}}}, 1000
      assert_receive {:agent_scale, ^session_id, {:run_finished, %{outcome: {:ok, :ok}}}}, 1000
    end
  end

  describe "cancel/1" do
    test "cancels an active run" do
      {:ok, session_id} =
        AgentScale.run(worker: AgentScale.Worker.Fake, request: %{steps: 100, delay: 1000})

      # Give it time to start
      Process.sleep(50)

      assert :ok = AgentScale.cancel(session_id)

      # Give the process time to terminate and be removed from registry
      Process.sleep(50)

      assert {:error, :not_found} = AgentScale.cancel(session_id)
    end

    test "returns error for unknown session" do
      assert {:error, :not_found} = AgentScale.cancel("nonexistent")
    end
  end

  describe "count_active/0" do
    test "counts active runs" do
      initial = AgentScale.count_active()

      {:ok, _} = AgentScale.run(worker: AgentScale.Worker.Fake, request: %{steps: 10, delay: 100})
      {:ok, _} = AgentScale.run(worker: AgentScale.Worker.Fake, request: %{steps: 10, delay: 100})

      # Give runs time to start
      Process.sleep(50)

      assert AgentScale.count_active() >= initial + 2
    end
  end
end
