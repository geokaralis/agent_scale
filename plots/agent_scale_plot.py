#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "matplotlib"]
# ///
"""
Plot AgentScale benchmark results.
Run: uv run plots/agent_scale_plot.py
"""

import json
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

data = json.load(
    open(Path(__file__).parent.parent / "bench" / "agent_scale_results.json")
)
A, B, C, meta = data["exp_a"], data["exp_b"], data["exp_c"], data["meta"]

fig, ((axA, axB), (axC, axD)) = plt.subplots(2, 2, figsize=(12, 9))
fig.suptitle(
    f"AgentScale — OTP {meta['otp']}, Elixir {meta['elixir']}, {meta['schedulers']} scheduler(s)"
)

# A: Memory footprint
n = np.array([r["n"] for r in A])
pm = np.array([r["proc_mem_mb"] for r in A])
tm = np.array([r["total_mem_mb"] for r in A])

axA.loglog(n, tm, "-o", label="total VM memory")
axA.loglog(n, pm, "-o", label="process memory")
axA.set_xlabel("concurrent agents")
axA.set_ylabel("memory (MB)")
axA.set_title("A: Memory Footprint")
axA.legend()
axA.grid(True, alpha=0.3)

# B: Throughput vs slots
slots = np.array([r["slots"] for r in B])
tput = np.array([r["throughput_rps"] for r in B])
ideal = np.array([r["ideal_rps"] for r in B])

axB.loglog(slots, ideal, "--", label="ideal")
axB.loglog(slots, tput, "o", label="measured")
axB.set_xlabel("slots")
axB.set_ylabel("runs/sec")
axB.set_title("B: Throughput vs Slots")
axB.legend()
axB.grid(True, alpha=0.3)

# C: Latency CDF
lat = np.array(C["latencies_ms"])
xs = np.sort(lat)
ys = np.arange(1, len(xs) + 1) / len(xs)

axC.plot(xs, ys)
axC.axvline(np.percentile(lat, 50), ls=":", label="p50")
axC.axvline(np.percentile(lat, 99), ls=":", label="p99")
axC.set_xlabel("latency (ms)")
axC.set_ylabel("CDF")
axC.set_title(f"C: Latency — {C['n']} runs, {C['slots']} slots")
axC.legend()
axC.grid(True, alpha=0.3)

# D: Bytes per agent
bpr = np.array([r["bytes_per_run"] for r in A]) / 1024

axD.semilogx(n, bpr, "-o")
axD.axhline(bpr[-1], ls="--", alpha=0.5)
axD.set_xlabel("concurrent agents")
axD.set_ylabel("KB per agent")
axD.set_title("D: Marginal Cost")
axD.grid(True, alpha=0.3)

plt.tight_layout()
out = Path(__file__).parent / "agent_scale_bench.png"
plt.savefig(out, dpi=150)
