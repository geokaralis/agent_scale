defmodule AgentScale do
  @moduledoc """
  Run and scale agent workloads. AgentScale wraps each run in a supervised
  process and meters how many hit the shared inference pool at once.

  ## Quick Start

      # Start a run with the fake worker (for testing)
      {:ok, session_id} = AgentScale.run(worker: AgentScale.Worker.Fake)

      # Subscribe to events
      AgentScale.subscribe(session_id)

      # Receive events
      receive do
        {:agent_scale, ^session_id, event} -> IO.inspect(event)
      end

  ## Two Primitives

  1. **`AgentScale.Limiter`** - A monitored counting semaphore with FIFO wait queue.
     Provides backpressure: many run processes queue against a fixed number of
     inference slots; dead holders are reclaimed automatically.

  2. **`AgentScale.Run`** - One supervised process per run. Waits for a slot, spawns
     the worker that streams events, forwards them, releases on any exit.

  ## Workers

  Workers implement the `AgentScale.Worker` behaviour:

      defmodule MyWorker do
        @behaviour AgentScale.Worker

        @impl true
        def stream(run_pid, request) do
          # Do work, send events...
          send(run_pid, {:agent_scale_event, {:my_event, %{data: "hello"}}})
          send(run_pid, {:agent_scale_done, :ok})
        end
      end

  """

  @doc """
  Start a new agent run.

  ## Options

    * `:worker` - The worker module implementing `AgentScale.Worker`. Defaults to
      `AgentScale.Worker.Fake`.
    * `:request` - Request data passed to the worker. Defaults to `%{}`.
    * `:session_id` - Unique identifier for this run. Auto-generated if not provided.
    * `:notify` - PID to receive metrics when the run completes.

  ## Returns

    * `{:ok, session_id}` on success
    * `{:error, reason}` on failure

  ## Examples

      {:ok, id} = AgentScale.run(worker: MyWorker, request: %{prompt: "Hello"})

  """
  @spec run(keyword()) :: {:ok, binary()} | {:error, term()}
  def run(opts \\ []) do
    session_id = opts[:session_id] || generate_session_id()
    opts = Keyword.put(opts, :session_id, session_id)

    case DynamicSupervisor.start_child(AgentScale.RunSupervisor, {AgentScale.Run, opts}) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, _} = err -> err
    end
  end

  @doc """
  Subscribe the calling process to events from a run.

  Events are delivered as `{:agent_scale, session_id, event}` messages.

  ## Examples

      AgentScale.subscribe(session_id)
      receive do
        {:agent_scale, ^session_id, {:run_started, _}} -> :ok
      end

  """
  @spec subscribe(binary()) :: :ok
  def subscribe(session_id) do
    {:ok, _} = Registry.register(AgentScale.PubSub, session_id, [])
    :ok
  end

  @doc """
  Cancel a running agent by session ID.

  This terminates the run process, which closes any connections and releases
  the inference slot.

  ## Examples

      AgentScale.cancel(session_id)

  """
  @spec cancel(binary()) :: :ok | {:error, :not_found}
  def cancel(session_id) do
    case Registry.lookup(AgentScale.Registry, session_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(AgentScale.RunSupervisor, pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Return the current count of active runs.
  """
  @spec count_active() :: non_neg_integer()
  def count_active do
    %{active: active} = DynamicSupervisor.count_children(AgentScale.RunSupervisor)
    active
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
