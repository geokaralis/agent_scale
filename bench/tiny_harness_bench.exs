defmodule AgentScale.Worker.TinyHarnessMock do
  @moduledoc """
  A mock worker that simulates tiny-harness ReAct-style agent runs.

  Emits realistic events matching tiny-harness's event taxonomy:
  - `{:llm_response, %{...}}` - After LLM inference
  - `{:tool_call, %{...}}` - When a tool is invoked
  - `{:tool_result, %{...}}` - After tool execution
  - `{:run_end, %{...}}` - When the agent cycle terminates

  ## Latency Model

  Real agent runs are dominated by LLM inference time. This mock simulates:
  - **LLM calls**: 500-2000ms (configurable, with jitter)
  - **Tool execution**: 10-100ms (fast local tools) or 100-500ms (API calls)
  - **Steps per run**: 1-10 (geometric distribution, most runs are short)

  ## Request Options

    * `:steps` - Fixed number of steps, or `:random` for geometric distribution. Default: `:random`
    * `:llm_latency_ms` - Base LLM latency. Default: 800
    * `:llm_jitter` - Jitter factor (0.0-1.0). Default: 0.5
    * `:tool_latency_ms` - Base tool latency. Default: 50
    * `:tool_jitter` - Tool jitter factor. Default: 0.8
    * `:tools_per_step` - Tools called per step. Default: 1
    * `:failure_rate` - Probability of run failure (0.0-1.0). Default: 0.0

  ## Example

      AgentScale.run(
        worker: AgentScale.Worker.TinyHarnessMock,
        request: %{steps: :random, llm_latency_ms: 1000}
      )

  """
  @behaviour AgentScale.Worker

  @default_opts %{
    steps: :random,
    llm_latency_ms: 800,
    llm_jitter: 0.5,
    tool_latency_ms: 50,
    tool_jitter: 0.8,
    tools_per_step: 1,
    failure_rate: 0.0
  }

  @impl true
  def stream(run_pid, request) do
    opts = Map.merge(@default_opts, request)
    steps = resolve_steps(opts.steps)

    try do
      run_loop(run_pid, opts, steps, 1)
    catch
      :error, :simulated_failure ->
        send(run_pid, {:agent_scale_done, {:error, :simulated_failure}})
    end
  end

  defp run_loop(run_pid, opts, total_steps, step) when step > total_steps do
    simulate_latency(opts.llm_latency_ms, opts.llm_jitter)

    send(
      run_pid,
      {:agent_scale_event,
       {:llm_response,
        %{
          step: step,
          content: "Final response after #{total_steps} steps",
          tool_calls: []
        }}}
    )

    send(
      run_pid,
      {:agent_scale_event,
       {:run_end,
        %{
          steps: total_steps,
          outcome: :success
        }}}
    )

    send(run_pid, {:agent_scale_done, %{steps: total_steps}})
  end

  defp run_loop(run_pid, opts, total_steps, step) do
    maybe_fail(opts.failure_rate)

    # LLM inference
    simulate_latency(opts.llm_latency_ms, opts.llm_jitter)

    tool_calls =
      for i <- 1..opts.tools_per_step do
        %{id: "call_#{step}_#{i}", name: "tool_#{rem(i, 5)}", args: %{step: step}}
      end

    send(
      run_pid,
      {:agent_scale_event,
       {:llm_response,
        %{
          step: step,
          content: nil,
          tool_calls: tool_calls
        }}}
    )

    for tool_call <- tool_calls do
      send(
        run_pid,
        {:agent_scale_event,
         {:tool_call,
          %{
            id: tool_call.id,
            name: tool_call.name,
            args: tool_call.args
          }}}
      )

      simulate_latency(opts.tool_latency_ms, opts.tool_jitter)

      send(
        run_pid,
        {:agent_scale_event,
         {:tool_result,
          %{
            id: tool_call.id,
            result: %{status: "ok", data: "result_#{step}"}
          }}}
      )
    end

    run_loop(run_pid, opts, total_steps, step + 1)
  end

  # Geometric distribution for step count - most runs are short, some are long
  # P(X = k) = (1-p)^(k-1) * p, mean = 1/p
  # With p=0.4, mean is 2.5 steps, but tail extends to 10+
  defp resolve_steps(:random) do
    p = 0.4
    max_steps = 10

    u = :rand.uniform()
    steps = ceil(:math.log(1 - u) / :math.log(1 - p))
    min(steps, max_steps)
  end

  defp resolve_steps(n) when is_integer(n), do: n

  defp simulate_latency(base_ms, jitter) do
    min_ms = base_ms * (1 - jitter / 2)
    range = base_ms * jitter
    actual_ms = round(min_ms + :rand.uniform() * range)
    Process.sleep(actual_ms)
  end

  defp maybe_fail(rate) when rate > 0 do
    if :rand.uniform() < rate, do: :erlang.error(:simulated_failure)
  end

  defp maybe_fail(_), do: :ok
end

defmodule TinyHarnessBench do
  @moduledoc """
  Benchmark simulating realistic tiny-harness agent workloads.

  Run: mix run bench/tiny_harness_bench.exs
  Quick: BENCH_QUICK=1 mix run bench/tiny_harness_bench.exs

  This benchmark uses AgentScale.Worker.TinyHarnessMock which simulates:
  - ReAct-style loops with LLM calls + tool execution
  - Realistic latency patterns (LLM: ~800ms, tools: ~50ms)
  - Variable step counts (geometric distribution, most runs 1-3 steps)
  """

  alias AgentScale.Worker.TinyHarnessMock

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
        Process.sleep(50)
        loop_idle(deadline)
    end
  end

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

  # Experiment 1: Throughput vs Concurrency
  def exp_throughput(slot_counts, runs_per_config, opts) do
    llm_ms = opts[:llm_ms] || 800
    tool_ms = opts[:tool_ms] || 50

    IO.puts("\n== Throughput vs Concurrency ==")
    IO.puts("   LLM: ~#{llm_ms}ms, Tool: ~#{tool_ms}ms, Steps: geometric(p=0.4)")

    for slots <- slot_counts do
      drain_limiter()
      AgentScale.Limiter.reset(slots)

      me = self()
      t0 = mono()

      for _ <- 1..runs_per_config do
        {:ok, _} =
          AgentScale.run(
            worker: TinyHarnessMock,
            request: %{steps: :random, llm_latency_ms: llm_ms, tool_latency_ms: tool_ms},
            notify: me
          )
      end

      metrics = collect_all_metrics(runs_per_config, [])
      makespan = mono() - t0

      total_ms = Enum.map(metrics, & &1.total_ms)
      wait_ms = Enum.map(metrics, & &1.wait_ms)

      throughput = Float.round(runs_per_config / (makespan / 1000), 2)
      avg_latency = Float.round(Enum.sum(total_ms) / length(total_ms), 0)
      avg_wait = Float.round(Enum.sum(wait_ms) / length(wait_ms), 0)

      IO.puts(
        "  slots=#{pad(slots)}  runs=#{runs_per_config}  makespan=#{pad(makespan)}ms  " <>
          "tput=#{throughput}/s  avg_lat=#{avg_latency}ms  avg_wait=#{avg_wait}ms"
      )

      %{
        slots: slots,
        runs: runs_per_config,
        makespan_ms: makespan,
        throughput_rps: throughput,
        avg_latency_ms: avg_latency,
        avg_wait_ms: avg_wait,
        p50_latency: percentile(total_ms, 50),
        p99_latency: percentile(total_ms, 99)
      }
    end
  end

  # Experiment 2: Burst Load
  def exp_burst(burst_size, slots, opts) do
    llm_ms = opts[:llm_ms] || 800
    tool_ms = opts[:tool_ms] || 50

    IO.puts("\n== Burst Load (#{burst_size} agents, #{slots} slots) ==")
    drain_limiter()
    AgentScale.Limiter.reset(slots)

    me = self()
    t0 = mono()

    for _ <- 1..burst_size do
      {:ok, _} =
        AgentScale.run(
          worker: TinyHarnessMock,
          request: %{steps: :random, llm_latency_ms: llm_ms, tool_latency_ms: tool_ms},
          notify: me
        )
    end

    submit_time = mono() - t0
    IO.puts("  Submitted #{burst_size} runs in #{submit_time}ms")

    completions = collect_completion_times(burst_size, t0, [])
    total_time = mono() - t0

    buckets = bucket_completions(completions, 500)

    IO.puts("  All completed in #{total_time}ms")
    IO.puts("  Completion rate over time:")

    for {bucket_start, count} <- Enum.take(buckets, 10) do
      bar = String.duplicate("█", min(count, 50))
      IO.puts("    #{pad(bucket_start)}-#{pad(bucket_start + 500)}ms: #{bar} (#{count})")
    end

    %{
      burst_size: burst_size,
      slots: slots,
      submit_time_ms: submit_time,
      total_time_ms: total_time,
      completion_buckets: buckets
    }
  end

  # Experiment 3: Sustained Load
  def exp_sustained(arrival_rate_per_sec, duration_sec, slots, opts) do
    llm_ms = opts[:llm_ms] || 800
    tool_ms = opts[:tool_ms] || 50

    IO.puts(
      "\n== Sustained Load (#{arrival_rate_per_sec}/s for #{duration_sec}s, #{slots} slots) =="
    )

    drain_limiter()
    AgentScale.Limiter.reset(slots)

    me = self()
    interval_ms = round(1000 / arrival_rate_per_sec)
    total_runs = arrival_rate_per_sec * duration_sec

    t0 = mono()

    submitter =
      spawn_link(fn ->
        for i <- 1..total_runs do
          {:ok, _} =
            AgentScale.run(
              worker: TinyHarnessMock,
              request: %{steps: :random, llm_latency_ms: llm_ms, tool_latency_ms: tool_ms},
              notify: me
            )

          if i < total_runs, do: Process.sleep(interval_ms)
        end
      end)

    metrics = collect_all_metrics(total_runs, [])
    total_time = mono() - t0

    Process.unlink(submitter)

    total_ms = Enum.map(metrics, & &1.total_ms)
    wait_ms = Enum.map(metrics, & &1.wait_ms)

    actual_throughput = Float.round(total_runs / (total_time / 1000), 2)

    IO.puts("  Target rate: #{arrival_rate_per_sec}/s, Actual throughput: #{actual_throughput}/s")

    IO.puts(
      "  Latency - p50: #{percentile(total_ms, 50)}ms, p90: #{percentile(total_ms, 90)}ms, p99: #{percentile(total_ms, 99)}ms"
    )

    IO.puts(
      "  Wait time - p50: #{percentile(wait_ms, 50)}ms, p90: #{percentile(wait_ms, 90)}ms, p99: #{percentile(wait_ms, 99)}ms"
    )

    %{
      arrival_rate: arrival_rate_per_sec,
      duration_sec: duration_sec,
      slots: slots,
      total_runs: total_runs,
      actual_throughput: actual_throughput,
      latency_p50: percentile(total_ms, 50),
      latency_p90: percentile(total_ms, 90),
      latency_p99: percentile(total_ms, 99),
      wait_p50: percentile(wait_ms, 50),
      wait_p90: percentile(wait_ms, 90),
      wait_p99: percentile(wait_ms, 99)
    }
  end

  # Experiment 4: Memory Under Load
  def exp_memory(concurrent_counts) do
    IO.puts("\n== Memory Usage ==")

    for n <- concurrent_counts do
      drain_limiter()
      AgentScale.Limiter.reset(n + 100)

      coord = self()

      for _ <- 1..n do
        {:ok, _} =
          AgentScale.run(
            worker: TinyHarnessBench.BarrierWorker,
            request: %{coord: coord}
          )
      end

      pids = collect_ready(n, [])

      :erlang.garbage_collect()
      proc_mem = :erlang.memory(:processes)
      total_mem = :erlang.memory(:total)
      procs = :erlang.system_info(:process_count)

      for pid <- pids, do: send(pid, :go)
      :ok = wait_idle()

      IO.puts(
        "  N=#{pad(n)}  procs=#{pad(procs)}  mem=#{Float.round(proc_mem / 1_048_576, 1)} MB  " <>
          "#{round(proc_mem / n)} B/agent"
      )

      %{
        concurrent: n,
        processes: procs,
        memory_mb: Float.round(proc_mem / 1_048_576, 2),
        total_memory_mb: Float.round(total_mem / 1_048_576, 2),
        bytes_per_agent: round(proc_mem / n)
      }
    end
  end

  ## Helpers

  defp collect_all_metrics(0, acc), do: acc

  defp collect_all_metrics(n, acc) do
    receive do
      {:agent_scale_metrics, _id, metrics} ->
        collect_all_metrics(n - 1, [metrics | acc])
    after
      120_000 -> raise "timeout waiting for metrics"
    end
  end

  defp collect_completion_times(0, _t0, acc), do: Enum.reverse(acc)

  defp collect_completion_times(n, t0, acc) do
    receive do
      {:agent_scale_metrics, _id, _metrics} ->
        collect_completion_times(n - 1, t0, [mono() - t0 | acc])
    after
      120_000 -> raise "timeout"
    end
  end

  defp collect_ready(0, acc), do: acc

  defp collect_ready(n, acc) do
    receive do
      {:ready, pid} -> collect_ready(n - 1, [pid | acc])
    after
      60_000 -> raise "barrier timeout"
    end
  end

  defp bucket_completions(times, bucket_size) do
    times
    |> Enum.group_by(fn t -> div(t, bucket_size) * bucket_size end)
    |> Enum.map(fn {k, v} -> {k, length(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp percentile(list, p) do
    sorted = Enum.sort(list)
    idx = min(length(sorted) - 1, round(p / 100 * length(sorted)))
    Enum.at(sorted, idx)
  end

  defp pad(x), do: String.pad_leading(to_string(x), 7)
end

defmodule TinyHarnessBench.BarrierWorker do
  @behaviour AgentScale.Worker

  @impl true
  def stream(run, %{coord: coord}) do
    send(coord, {:ready, self()})

    receive do
      :go -> send(run, {:agent_scale_done, :ok})
    end
  end
end

defmodule TinyHarnessBench.JSON do
  def encode(term), do: enc(term)

  defp enc(m) when is_map(m),
    do: "{" <> Enum.map_join(m, ",", fn {k, v} -> "#{enc(to_string(k))}:#{enc(v)}" end) <> "}"

  defp enc(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &enc/1) <> "]"
  defp enc({k, v}), do: "{#{enc(to_string(k))}:#{enc(v)}}"
  defp enc(b) when is_binary(b), do: "\"" <> String.replace(b, "\"", "\\\"") <> "\""
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(nil), do: "null"
  defp enc(a) when is_atom(a), do: "\"#{a}\""
  defp enc(n) when is_float(n), do: :erlang.float_to_binary(n, [{:decimals, 2}])
  defp enc(n), do: to_string(n)
end

# ── Run benchmarks ────────────────────────────────────────────────────────────
quick_mode = System.get_env("BENCH_QUICK") == "1"

{llm_ms, tool_ms, runs, burst_size, sustained_rate, sustained_dur, mem_counts} =
  if quick_mode do
    IO.puts("Running in QUICK mode (reduced latencies)\n")
    {50, 10, 30, 50, 5, 5, [100, 500, 1000]}
  else
    {800, 50, 100, 200, 10, 10, [100, 500, 1000, 5000]}
  end

opts = [llm_ms: llm_ms, tool_ms: tool_ms]

IO.puts(String.duplicate("=", 70))
IO.puts("AgentScale + tiny-harness Mock Benchmark")
IO.puts(String.duplicate("=", 70))
IO.puts("LLM latency: ~#{llm_ms}ms, Tool latency: ~#{tool_ms}ms")

throughput = TinyHarnessBench.exp_throughput([4, 8, 16, 32, 64], runs, opts)
burst = TinyHarnessBench.exp_burst(burst_size, 32, opts)
sustained = TinyHarnessBench.exp_sustained(sustained_rate, sustained_dur, 32, opts)
memory = TinyHarnessBench.exp_memory(mem_counts)

meta = %{
  quick_mode: quick_mode,
  llm_latency_ms: llm_ms,
  tool_latency_ms: tool_ms,
  schedulers: :erlang.system_info(:schedulers_online),
  otp: List.to_string(:erlang.system_info(:otp_release)),
  elixir: System.version()
}

results = %{
  meta: meta,
  throughput: throughput,
  burst: burst,
  sustained: sustained,
  memory: memory
}

File.write!("bench/tiny_harness_results.json", TinyHarnessBench.JSON.encode(results))

IO.puts("\n" <> String.duplicate("=", 70))
IO.puts("Benchmark complete! Results saved to bench/tiny_harness_results.json")
