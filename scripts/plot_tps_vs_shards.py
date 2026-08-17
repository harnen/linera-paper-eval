#!/usr/bin/env python3
"""Plots max sustained TPS vs. number of shard workers (each pinned to a fixed core
budget), with a gray dashed reference line showing perfect linear scaling from the first
data point, so departure from linearity is easy to read at a glance.

Two input shapes are accepted, auto-detected from the header:
  - A single run's summary (run_shard_count_sweep.sh's output): num_shards,num_clients,
    requested_bps,committed,failed,achieved_bps,achieved_tps,p25_ms,p50_ms,p95_ms,
    first_bad_clients. One point per shard count, no error bars.
  - A repeated sweep's long-format table (run_repeated_shard_sweep.sh's all_iterations.csv):
    the same columns plus a leading `iteration` column, one row per (iteration, num_shards).
    Plotted as the per-shard-count *median* achieved_tps, with error bars spanning
    [min, max] across iterations -- deliberately not mean +/- stddev, since a handful of
    iterations is too few to assume normality, and min/max reports exactly what was
    observed rather than a distributional guess.

Rows with an empty/missing achieved_tps (no sustained level found for that shard count)
are skipped.

An optional inset shows per-worker throughput (achieved_tps / num_shards) vs. num_shards --
if scaling were perfectly linear this would be a flat line; any droop is the marginal cost
of adding workers. Pass --single-worker-csv to also draw a horizontal reference line at an
*isolated* single worker's own ceiling (find_max_single_chain_tps.sh's output: peak
achieved_tps across its requested_bps ramp) -- the gap between that reference and the
in-committee per-worker points is the overhead of running alongside other workers
(proxy/storage-server contention, cross-chain routing, etc.), isolated from pure
per-worker compute capacity.

Usage: plot_tps_vs_shards.py <csv> [output_path] [--single-worker-csv <csv>]
  output_path defaults to <csv's directory>/tps_vs_shards.png
"""
import argparse
import statistics
from pathlib import Path

import matplotlib.pyplot as plt


def read_summary(path):
    """Returns {num_shards: [achieved_tps, ...]} -- one measurement per iteration (or a
    single-element list per shard count for a non-repeated summary)."""
    import csv

    by_shards = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if not row.get("achieved_tps"):
                continue
            n = int(row["num_shards"])
            by_shards.setdefault(n, []).append(float(row["achieved_tps"]))
    return by_shards


def read_single_worker_ceiling(path):
    """Peak achieved_tps across a find_max_single_chain_tps.sh ramp: the CSV records every
    requested_bps level probed, and throughput falls off past the true ceiling once the
    worker is overloaded, so the max over all rows is the sustained peak, not the last row."""
    import csv

    peak = 0.0
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if not row.get("achieved_tps"):
                continue
            peak = max(peak, float(row["achieved_tps"]))
    return peak


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("output_path", type=Path, nargs="?")
    parser.add_argument(
        "--single-worker-csv",
        type=Path,
        default=None,
        help="find_max_single_chain_tps.sh output CSV; draws the isolated single-worker "
        "ceiling as a reference line in the per-worker inset.",
    )
    args = parser.parse_args()

    output_path = args.output_path or args.csv_path.parent / "tps_vs_shards.png"

    by_shards = read_summary(args.csv_path)
    if not by_shards:
        print("No sustained-throughput rows found in", args.csv_path)
        raise SystemExit(1)

    shard_counts = sorted(by_shards)
    repeated = max(len(v) for v in by_shards.values()) > 1

    medians = [statistics.median(by_shards[n]) for n in shard_counts]
    lo = [min(by_shards[n]) for n in shard_counts]
    hi = [max(by_shards[n]) for n in shard_counts]
    err_lo = [m - l for m, l in zip(medians, lo)]
    err_hi = [h - m for m, h in zip(medians, hi)]

    # Perfect-linear-scaling reference, anchored at the first (smallest shard count) point.
    base_shards, base_tps = shard_counts[0], medians[0]
    per_shard = base_tps / base_shards
    ref_x = [shard_counts[0], shard_counts[-1]]
    ref_y = [per_shard * x for x in ref_x]

    fig, ax = plt.subplots(figsize=(7.5, 5))
    ax.plot(
        ref_x, ref_y, color="gray", linestyle="--", linewidth=1.2,
        label=f"linear from {base_shards}-worker point",
    )
    label = "median max sustained TPS" if repeated else "measured max sustained TPS"
    if repeated:
        ax.errorbar(
            shard_counts, medians, yerr=[err_lo, err_hi],
            color="tab:blue", marker="o", markersize=5, linewidth=1.5,
            capsize=3, label=label,
        )
    else:
        ax.plot(
            shard_counts, medians, color="tab:blue", marker="o", markersize=5,
            linewidth=1.5, label=label,
        )

    ax.set_xlabel("Number of workers (shards)")
    ax.set_ylabel("Max sustained throughput (tx/s)")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.legend(loc="upper left", frameon=True)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)

    # Per-worker-TPS inset: same x-axis, y = achieved_tps / num_shards. Flat = perfect
    # scaling; a downward slope quantifies the marginal cost of each extra worker.
    per_worker_medians = [m / n for m, n in zip(medians, shard_counts)]
    per_worker_lo = [l / n for l, n in zip(lo, shard_counts)]
    per_worker_hi = [h / n for h, n in zip(hi, shard_counts)]
    pw_err_lo = [m - l for m, l in zip(per_worker_medians, per_worker_lo)]
    pw_err_hi = [h - m for m, h in zip(per_worker_medians, per_worker_hi)]

    inset = ax.inset_axes([0.53, 0.1, 0.44, 0.4])
    if repeated:
        inset.errorbar(
            shard_counts, per_worker_medians, yerr=[pw_err_lo, pw_err_hi],
            color="tab:blue", marker="o", markersize=3, linewidth=1.0, capsize=2,
        )
    else:
        inset.plot(
            shard_counts, per_worker_medians, color="tab:blue", marker="o",
            markersize=3, linewidth=1.0,
        )
    if args.single_worker_csv is not None:
        ceiling = read_single_worker_ceiling(args.single_worker_csv)
        inset.axhline(
            ceiling, color="tab:red", linestyle="--", linewidth=1.0,
            label="isolated single worker",
        )
        inset.legend(loc="lower left", fontsize=6, frameon=True)
    inset.set_xlabel("workers", fontsize=7)
    inset.set_ylabel("TPS / worker", fontsize=7)
    inset.tick_params(labelsize=6)
    inset.grid(True, linestyle=":", linewidth=0.4, alpha=0.6)
    inset.set_xlim(left=0)
    inset.set_ylim(bottom=0)

    fig.tight_layout()
    fig.savefig(output_path, dpi=200)
    fig.savefig(output_path.with_suffix(".pdf"))
    print(f"Wrote {output_path} and {output_path.with_suffix('.pdf')}")


if __name__ == "__main__":
    main()
