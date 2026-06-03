defmodule AgentScale.Limiter do
  @moduledoc """
  A monitored counting semaphore with a FIFO wait queue.

  Lets a huge number of run processes queue against a fixed number of
  inference slots. Slots are monitored, so a run that dies while holding or
  waiting is reclaimed automatically.

  ## Messages

  When a slot is granted, the requesting process receives:

      {:agent_scale_slot, ref}

  Where `ref` is the monitor reference that must be passed to `release/1`.
  """
  use GenServer

  @doc """
  Start the limiter with the given options.

  ## Options

    * `:max` - Maximum number of concurrent slots. Defaults to 4.

  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request a slot for the given process.

  The process will receive `{:agent_scale_slot, ref}` when a slot is available.
  The request is queued (FIFO) if no slots are available.
  """
  @spec request(pid()) :: :ok
  def request(pid), do: GenServer.cast(__MODULE__, {:request, pid})

  @doc """
  Release a slot previously granted.

  The `ref` must be the monitor reference received in `{:agent_scale_slot, ref}`.
  """
  @spec release(reference()) :: :ok
  def release(ref), do: GenServer.cast(__MODULE__, {:release, ref})

  @doc """
  Reset the limiter with a new maximum slot count.

  This clears all current holders and the wait queue.
  """
  @spec reset(non_neg_integer()) :: :ok
  def reset(max), do: GenServer.call(__MODULE__, {:reset, max}, :infinity)

  @impl true
  def init(opts) do
    {:ok, %{free: opts[:max] || 4, queue: :queue.new(), holding: %{}}}
  end

  @impl true
  def handle_call({:reset, max}, _from, s) do
    for {ref, _} <- s.holding, do: Process.demonitor(ref, [:flush])
    for {ref, _} <- :queue.to_list(s.queue), do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{free: max, queue: :queue.new(), holding: %{}}}
  end

  @impl true
  def handle_cast({:request, pid}, %{free: free} = s) when free > 0 do
    ref = Process.monitor(pid)
    send(pid, {:agent_scale_slot, ref})
    {:noreply, %{s | free: free - 1, holding: Map.put(s.holding, ref, pid)}}
  end

  def handle_cast({:request, pid}, s) do
    ref = Process.monitor(pid)
    {:noreply, %{s | queue: :queue.in({ref, pid}, s.queue)}}
  end

  def handle_cast({:release, ref}, s) do
    if Map.has_key?(s.holding, ref), do: {:noreply, hand_off(ref, s)}, else: {:noreply, s}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    if Map.has_key?(s.holding, ref) do
      {:noreply, hand_off(ref, s)}
    else
      {:noreply, %{s | queue: :queue.filter(fn {r, _} -> r != ref end, s.queue)}}
    end
  end

  defp hand_off(ref, s) do
    Process.demonitor(ref, [:flush])
    holding = Map.delete(s.holding, ref)

    case :queue.out(s.queue) do
      {{:value, {wref, wpid}}, q} ->
        send(wpid, {:agent_scale_slot, wref})
        %{s | queue: q, holding: Map.put(holding, wref, wpid)}

      {:empty, _} ->
        %{s | free: s.free + 1, holding: holding}
    end
  end
end
