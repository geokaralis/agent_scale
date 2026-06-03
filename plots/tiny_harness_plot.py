#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "matplotlib"]
# ///
"""
Plot tiny-harness simulation benchmark results.
Run: uv run plots/tiny_harness_plot.py
"""

import json
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

data = json.load(
    open(Path(__file__).parent.parent / "bench" / "tiny_harness_results.json")
)
meta = data["meta"]
throughput = data["throughput"]
burst = data["burst"]
sustained = data["sustained"]
memory = data["memory"]

fig, ((axA, axB), (axC, axD)) = plt.subplots(2, 2, figsize=(12, 9))
mode = "quick" if meta.get("quick_mode") else "realistic"
fig.suptitle(
    f"AgentScale + tiny-harness — LLM ~{meta['llm_latency_ms']}ms, Tool ~{meta['tool_latency_ms']}ms ({mode})"
)

# A: Throughput vs slots
slots = np.array([r["slots"] for r in throughput])
tput = np.array([r["throughput_rps"] for r in throughput])
avg_lat = np.array([r["avg_latency_ms"] for r in throughput])

ax2 = axA.twinx()
axA.bar(range(len(slots)), tput, alpha=0.7, label="throughput")
ax2.plot(range(len(slots)), avg_lat, "o-", color="C1", label="avg latency")
axA.set_xticks(range(len(slots)))
axA.set_xticklabels(slots)
axA.set_xlabel("slots")
axA.set_ylabel("runs/sec")
ax2.set_ylabel("avg latency (ms)")
axA.set_title("A: Throughput & Latency")
axA.legend(loc="upper left")
ax2.legend(loc="upper right")

# B: Burst completion
buckets = burst["completion_buckets"]
times, counts = [], []
for b in buckets:
    for k, v in b.items():
        times.append(int(k))
        counts.append(v)

axB.bar(times, counts, width=400, align="edge", alpha=0.7)
axB.axvline(burst["submit_time_ms"], ls="--", color="C1", label=f"submit done")
axB.set_xlabel("time (ms)")
axB.set_ylabel("completions")
axB.set_title(f"B: Burst — {burst['burst_size']} agents, {burst['slots']} slots")
axB.legend()

# C: Sustained load latency percentiles
labels = ["p50", "p90", "p99"]
latencies = [
    sustained["latency_p50"],
    sustained["latency_p90"],
    sustained["latency_p99"],
]
waits = [sustained["wait_p50"], sustained["wait_p90"], sustained["wait_p99"]]

x = np.arange(len(labels))
axC.bar(x - 0.2, latencies, 0.4, label="total")
axC.bar(x + 0.2, waits, 0.4, label="wait")
axC.set_xticks(x)
axC.set_xticklabels(labels)
axC.set_ylabel("time (ms)")
axC.set_title(
    f"C: Sustained — {sustained['arrival_rate']}/s target, {sustained['actual_throughput']}/s actual"
)
axC.legend()

# D: Memory
n = np.array([r["concurrent"] for r in memory])
mem_mb = np.array([r["memory_mb"] for r in memory])
kb_per = np.array([r["bytes_per_agent"] for r in memory]) / 1024

ax2d = axD.twinx()
axD.semilogx(n, mem_mb, "-o", label="memory (MB)")
ax2d.semilogx(n, kb_per, "-s", color="C1", label="KB/agent")
axD.set_xlabel("concurrent agents")
axD.set_ylabel("memory (MB)")
ax2d.set_ylabel("KB per agent")
axD.set_title("D: Memory Footprint")
axD.legend(loc="upper left")
ax2d.legend(loc="upper right")

plt.tight_layout()
out = Path(__file__).parent / "tiny_harness_bench.png"
plt.savefig(out, dpi=150)
print(f"saved {out}")
