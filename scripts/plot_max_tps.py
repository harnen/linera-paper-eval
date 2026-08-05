#!/usr/bin/env python3
"""Plots throughput (TPS) vs. latency from find_max_tps.sh's per-traffic-mode CSVs,
matching the paper's Section VII.C / Fig. 5 style: one line per traffic pattern, no
baseline comparison. Each point is one ramp level (client count); the marker is p50
latency, error bars span p25-p95 from the same level's committed-block duration
distribution (no repeated trials, so this substitutes for run-to-run error bars).

Usage: plot_max_tps.py <results_dir> [output_path]
  results_dir must contain independent.csv, mixed.csv, full.csv (find_max_tps.sh's
  SUMMARY_CSV format, with achieved_tps/p25_ms/p50_ms/p95_ms columns).
  output_path defaults to <results_dir>/max_tps.png
"""
import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt

MODES = [
    ("independent", "Independent", "tab:blue", "o"),
    ("mixed", "Mixed", "tab:orange", "s"),
    ("full", "Full cross-chain", "tab:green", "^"),
]


def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            rows.append(row)
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    results_dir = Path(sys.argv[1])
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else results_dir / "max_tps.png"

    fig, ax = plt.subplots(figsize=(7, 4.5))

    for key, label, color, marker in MODES:
        csv_path = results_dir / f"{key}.csv"
        if not csv_path.exists():
            print(f"skipping {label}: {csv_path} not found")
            continue
        rows = load_csv(csv_path)
        # Only plot levels that actually committed blocks without failures -- a failed
        # level's latency numbers aren't a meaningful sustained-throughput data point.
        rows = [r for r in rows if int(r["failed"]) == 0]

        x = [float(r["achieved_tps"]) for r in rows]
        p25 = [float(r["p25_ms"]) / 1000 for r in rows]
        p50 = [float(r["p50_ms"]) / 1000 for r in rows]
        p95 = [float(r["p95_ms"]) / 1000 for r in rows]
        yerr_lower = [max(0.0, m - lo) for m, lo in zip(p50, p25)]
        yerr_upper = [max(0.0, hi - m) for m, hi in zip(p50, p95)]

        ax.errorbar(
            x, p50, yerr=[yerr_lower, yerr_upper],
            marker=marker, color=color, label=label,
            capsize=3, linewidth=1.5, markersize=5,
        )

    ax.set_xlabel("Throughput (tx/s)")
    ax.set_ylabel("Latency (s)")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.legend(loc="upper left", frameon=True)
    fig.tight_layout()

    fig.savefig(output_path, dpi=200)
    fig.savefig(output_path.with_suffix(".pdf"))
    print(f"Wrote {output_path} and {output_path.with_suffix('.pdf')}")


if __name__ == "__main__":
    main()
