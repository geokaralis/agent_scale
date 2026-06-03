defmodule Bench do
  @moduledoc "Load test for AgentScale. Run: ELIXIR_ERL_OPTIONS='+P 2000000' mix run bench/agent_scale_bench.exs"

  def mono, do: System.monotonic_time(:millisecond)

  def wait_idle(timeout \\ 600_000) do
    deadline = mono() + timeout
    loop_idle(deadline)
  end

  defp loop_idle(deadline) do
    %{active: a} = DynamicSupervisor.count_children(AgentScale.RunSupervisor)

    cond do
      a == 0 ->
        :ok

      mono() > deadline ->
        {:timeout, a}

      true ->
        Process.sleep(15)
        loop_idle(deadline)
    end
  end

  # Experiment A: massive concurrency. Hold N agents provably alive at once
  # (barrier), measure peak process memory. Showcases "massively + concurrent".
  def exp_a(ns) do
    IO.puts("\n== A: massive concurrency ==")

    for n <- ns do
      Bench.drain_limiter()
      AgentScale.Limiter.reset(n + 1_000)
      coord = self()

      Enum.each(1..n, fn _ ->
        {:ok, _} = AgentScale.run(worker: Bench.Barrier, request: %{coord: coord})
      end)

      workers = collect_ready(n, [])
      :erlang.garbage_collect()
      proc_mem = :erlang.memory(:processes)
      total_mem = :erlang.memory(:total)
      procs = :erlang.system_info(:process_count)

      Enum.each(workers, &send(&1, :go))
      :ok = wait_idle()

      row = %{
        n: n,
        peak_procs: procs,
        proc_mem_mb: Float.round(proc_mem / 1_048_576, 2),
        total_mem_mb: Float.round(total_mem / 1_048_576, 2),
        bytes_per_run: round(proc_mem / n)
      }

      IO.puts(
        "  N=#{pad(n)}  procs=#{pad(procs)}  proc_mem=#{row.proc_mem_mb} MB  #{row.bytes_per_run} B/run"
      )

      row
    end
  end

  defp collect_ready(0, acc), do: acc

  defp collect_ready(n, acc) do
    receive do
      {:ready, pid} -> collect_ready(n - 1, [pid | acc])
    after
      120_000 -> raise "barrier timeout, missing #{n} readies"
    end
  end

  # Experiment B: backpressure. Throughput vs number of slots. Showcases the
  # limiter: completed runs/sec should track slots / service_time (linear).
  def exp_b(slots_list, service_ms, runs_per_slot) do
    IO.puts("\n== B: backpressure throughput (service=#{service_ms}ms) ==")

    for c <- slots_list do
      n = c * runs_per_slot
      Bench.drain_limiter()
      AgentScale.Limiter.reset(c)
      t0 = mono()

      Enum.each(1..n, fn _ ->
        {:ok, _} = AgentScale.run(worker: AgentScale.Worker.Bench, request: %{sleep: service_ms})
      end)

      :ok = wait_idle()
      makespan = mono() - t0

      tput = Float.round(n / (makespan / 1000), 1)
      ideal = Float.round(c / (service_ms / 1000), 1)

      IO.puts(
        "  slots=#{pad(c)}  n=#{pad(n)}  makespan=#{pad(makespan)}ms  tput=#{tput}/s  (ideal #{ideal}/s)"
      )

      %{slots: c, n: n, makespan_ms: makespan, throughput_rps: tput, ideal_rps: ideal}
    end
  end

  # Experiment C: latency under backpressure. Per-run end-to-end latency with
  # a fixed slot budget. Showcases orderly queueing (graceful, not collapse).
  def exp_c(n, slots, service_ms) do
    IO.puts("\n== C: latency CDF (n=#{n}, slots=#{slots}, service=#{service_ms}ms) ==")
    Bench.drain_limiter()
    AgentScale.Limiter.reset(slots)
    me = self()

    Enum.each(1..n, fn _ ->
      {:ok, _} =
        AgentScale.run(worker: AgentScale.Worker.Bench, request: %{sleep: service_ms}, notify: me)
    end)

    lat = collect_metrics(n, [])
    :ok = wait_idle()

    sorted = Enum.sort(lat)

    IO.puts(
      "  p50=#{pct(sorted, 50)}ms  p90=#{pct(sorted, 90)}ms  p99=#{pct(sorted, 99)}ms  max=#{List.last(sorted)}ms"
    )

    %{n: n, slots: slots, service_ms: service_ms, latencies_ms: sorted}
  end

  defp collect_metrics(0, acc), do: acc

  defp collect_metrics(n, acc) do
    receive do
      {:agent_scale_metrics, _id, %{total_ms: t}} -> collect_metrics(n - 1, [t | acc])
    after
      120_000 -> raise "metrics timeout"
    end
  end

  defp pct(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * length(sorted))))

  defp pad(x), do: String.pad_leading(to_string(x), 7)

  # let the limiter finish processing release/DOWN backlog before reconfiguring
  def drain_limiter do
    pid = Process.whereis(AgentScale.Limiter)

    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, 0} ->
        :ok

      _ ->
        Process.sleep(20)
        drain_limiter()
    end
  end
end

defmodule Bench.JSON do
  def encode(term), do: enc(term)

  defp enc(m) when is_map(m),
    do: "{" <> Enum.map_join(m, ",", fn {k, v} -> "#{enc(to_string(k))}:#{enc(v)}" end) <> "}"

  defp enc(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &enc/1) <> "]"
  defp enc(b) when is_binary(b), do: "\"" <> b <> "\""
  defp enc(a) when is_atom(a), do: "\"#{a}\""
  defp enc(n), do: to_string(n)
end

defmodule Bench.Barrier do
  @behaviour AgentScale.Worker
  @impl true
  def stream(run, %{coord: coord}) do
    send(coord, {:ready, self()})

    receive do
      :go -> send(run, {:agent_scale_done, :ok})
    end
  end
end

a = Bench.exp_a([1_000, 5_000, 10_000, 25_000, 50_000, 100_000])
b = Bench.exp_b([1, 2, 4, 8, 16, 32, 64, 128, 256, 512], 50, 30)
c = Bench.exp_c(3_000, 60, 40)

meta = %{
  schedulers: :erlang.system_info(:schedulers_online),
  otp: List.to_string(:erlang.system_info(:otp_release)),
  elixir: System.version()
}

json =
  %{meta: meta, exp_a: a, exp_b: b, exp_c: c}
  |> :erlang.term_to_binary()

File.write!("bench/agent_scale_results.bin", json)
File.write!(
  "bench/agent_scale_results.json",
  Bench.JSON.encode(%{meta: meta, exp_a: a, exp_b: b, exp_c: c})
)

IO.puts("\nwrote bench/results.json")
