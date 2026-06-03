defmodule AgentScale.Worker do
  @moduledoc """
  Workers implement the actual agent logic or connect to external agent services.

  They stream events back to the run process.

  ## Example

      defmodule MyWorker do
        @behaviour AgentScale.Worker

        @impl true
        def stream(run_pid, request) do
          # Simulate some work
          send(run_pid, {:agent_scale_event, {:step, %{n: 1}}})
          Process.sleep(100)
          send(run_pid, {:agent_scale_event, {:step, %{n: 2}}})
          send(run_pid, {:agent_scale_done, :completed})
        end
      end

  ## Messages to Send

    * `{:agent_scale_event, event}` - Forward an event to subscribers
    * `{:agent_scale_done, result}` - Signal successful completion

  If the worker process exits without sending `:agent_scale_done`, the run
  will handle it gracefully (normal exit is ignored, crashes are reported).
  """

  @doc """
  Stream events from an agent run.

  Called in a spawned process linked to the run. Should send events via
  `send(run_pid, {:agent_scale_event, event})` and complete with
  `send(run_pid, {:agent_scale_done, result})`.

  ## Parameters

    * `run_pid` - The PID of the `AgentScale.Run` process to send events to
    * `request` - The request map passed to `AgentScale.run/1`

  """
  @callback stream(run_pid :: pid(), request :: map()) :: any()
end

defmodule AgentScale.Worker.Fake do
  @moduledoc """
  A fake worker for testing. Emits synthetic events with configurable delay.

  ## Request Options

    * `:steps` - Number of step events to emit. Defaults to 3.
    * `:delay` - Milliseconds between steps. Defaults to 100.

  """
  @behaviour AgentScale.Worker

  @impl true
  def stream(run, request) do
    steps = Map.get(request, :steps, 3)
    delay = Map.get(request, :delay, 100)

    for i <- 1..steps do
      Process.sleep(delay)
      send(run, {:agent_scale_event, {:step, %{n: i, total: steps}}})
    end

    send(run, {:agent_scale_done, :ok})
  end
end

defmodule AgentScale.Worker.Bench do
  @moduledoc """
  A benchmark worker that sleeps for a configurable duration.

  ## Request Options

    * `:sleep` - Milliseconds to sleep. Defaults to 50.

  """
  @behaviour AgentScale.Worker

  @impl true
  def stream(run, request) do
    Process.sleep(Map.get(request, :sleep, 50))
    send(run, {:agent_scale_done, :ok})
  end
end
