#!/usr/bin/env python3
"""Plots max sustained TPS vs. number of shard workers (each pinned to a fixed core
budget), with a gray dashed reference line showing perfect linear scaling from the first
data point, so departure from linearity is easy to read at a glance.

Usage: plot_tps_vs_shards.py <summary_csv> [output_path]
  summary_csv is run_shard_count_sweep.sh's output (num_shards,num_clients,requested_bps,
  committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms). Rows with an empty
  achieved_tps (no sustained level found for that shard count) are skipped.
  output_path defaults to <summary_csv's directory>/tps_vs_shards.png
"""
import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt


def read_summary(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if not row["achieved_tps"]:
                continue
            rows.append((int(row["num_shards"]), float(row["achieved_tps"])))
    rows.sort()
    return rows


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    csv_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else csv_path.parent / "tps_vs_shards.png"

    rows = read_summary(csv_path)
    if not rows:
        print("No sustained-throughput rows found in", csv_path)
        sys.exit(1)
    shards = [n for n, _ in rows]
    tps = [t for _, t in rows]

    # Perfect-linear-scaling reference, anchored at the first (smallest shard count) point.
    base_shards, base_tps = rows[0]
    per_shard = base_tps / base_shards
    ref_x = [shards[0], shards[-1]]
    ref_y = [per_shard * x for x in ref_x]

    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.plot(ref_x, ref_y, color="gray", linestyle="--", linewidth=1.2,
             label=f"linear from {base_shards}-worker point")
    ax.plot(shards, tps, color="tab:blue", marker="o", markersize=5, linewidth=1.5,
            label="measured max sustained TPS")

    ax.set_xlabel("Number of workers (shards)")
    ax.set_ylabel("Max sustained throughput (tx/s)")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.legend(loc="upper left", frameon=True)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)

    fig.tight_layout()
    fig.savefig(output_path, dpi=200)
    fig.savefig(output_path.with_suffix(".pdf"))
    print(f"Wrote {output_path} and {output_path.with_suffix('.pdf')}")


if __name__ == "__main__":
    main()
