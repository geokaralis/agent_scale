defmodule AgentScale.Run do
  @moduledoc """
  A supervised process owns one agent run.

  The worker streams events from the actual agent implementation.
  Run meters the slot, forwards events, and releases on any exit.

  ## Messages

  Workers send events to the run process:

    * `{:agent_scale_event, event}` - Forward an event to subscribers
    * `{:agent_scale_done, result}` - Signal successful completion

  Subscribers receive events as:

    * `{:agent_scale, session_id, event}`

  The notified process receives metrics:

    * `{:agent_scale_metrics, session_id, %{wait_ms: _, total_ms: _}}`

  """
  use GenServer, restart: :transient

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {AgentScale.Registry, opts[:session_id]}}
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session_id: opts[:session_id],
      worker: opts[:worker] || AgentScale.Worker.Fake,
      request: opts[:request] || %{},
      notify: opts[:notify],
      enqueued_at: mono(),
      started_at: nil,
      slot: nil,
      stream_pid: nil
    }

    AgentScale.Limiter.request(self())
    {:ok, state}
  end

  @impl true
  def handle_info({:agent_scale_slot, ref}, s) do
    emit(s, {:run_started, %{}})
    me = self()
    pid = spawn_link(fn -> s.worker.stream(me, s.request) end)
    {:noreply, %{s | slot: ref, stream_pid: pid, started_at: mono()}}
  end

  def handle_info({:agent_scale_event, event}, s) do
    emit(s, event)
    {:noreply, s}
  end

  def handle_info({:agent_scale_done, result}, s) do
    emit(s, {:run_finished, %{outcome: {:ok, result}}})
    report(s)
    {:stop, :normal, s}
  end

  def handle_info({:EXIT, pid, :normal}, %{stream_pid: pid} = s), do: {:noreply, s}

  def handle_info({:EXIT, pid, reason}, %{stream_pid: pid} = s) do
    emit(s, {:run_finished, %{outcome: {:error, reason}}})
    report(s)
    {:stop, :normal, s}
  end

  def handle_info({:EXIT, _pid, reason}, s), do: {:stop, reason, s}

  @impl true
  def terminate(_reason, %{slot: ref}) when not is_nil(ref) do
    AgentScale.Limiter.release(ref)
  end

  def terminate(_reason, _state), do: :ok

  defp emit(%{session_id: id}, {_type, _payload} = event) do
    Registry.dispatch(AgentScale.PubSub, id, fn subs ->
      for {pid, _} <- subs, do: send(pid, {:agent_scale, id, event})
    end)
  end

  defp report(%{notify: nil}), do: :ok

  defp report(%{notify: pid} = s) do
    now = mono()

    send(
      pid,
      {:agent_scale_metrics, s.session_id,
       %{wait_ms: (s.started_at || now) - s.enqueued_at, total_ms: now - s.enqueued_at}}
    )
  end

  defp mono, do: System.monotonic_time(:millisecond)
end
