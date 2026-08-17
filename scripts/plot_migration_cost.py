#!/usr/bin/env python3
"""Plots the cost of a runtime chain-to-shard migration from run_migration_cost_experiment.sh's
output: (a) a handover timeline (per-block latency vs. elapsed time for the migrated chains,
with the migration trigger marked) and (b) a CDF of per-block confirmation latency, migrated
vs. control chains, over the whole run.

Usage: plot_migration_cost.py <out_dir> [output_prefix]
  out_dir is a run_migration_cost_experiment.sh OUT_DIR (contains tagged_transfers.csv and
  migration_trigger.csv). output_prefix defaults to <out_dir>/migration_cost -- writes
  <prefix>_timeline.{png,pdf} and <prefix>_cdf.{png,pdf}.

Note on (b): the CDF includes every block over the whole run for both groups, migrate-group
blocks before AND after the handover -- this is the amortized cost including the handover
spike, not a "steady state after migration" number. If you want the latter, filter
tagged_transfers.csv to ts_within_experiment > the migration trigger time first.
"""
import csv
import sys
import textwrap
from pathlib import Path

import matplotlib.pyplot as plt


def read_tagged_transfers(path):
    rows = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if row["result"] != "committed":
                continue
            rows.append(
                {
                    "chain_id": row["chain_id"],
                    "ts": float(row["ts_within_experiment"]),
                    "duration_ms": float(row["duration_micros"]) / 1000.0,
                    "group": row["group"],
                }
            )
    return rows


def read_migration_trigger(out_dir):
    path = out_dir / "migration_trigger.csv"
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        return float(next(reader)["migration_trigger_elapsed_seconds"])


def plot_timeline(rows, trigger_s, output_prefix):
    migrate_rows = sorted((r for r in rows if r["group"] == "migrate"), key=lambda r: r["ts"])
    if not migrate_rows:
        print("No migrate-group rows found -- skipping timeline plot")
        return

    fig, ax = plt.subplots(figsize=(8, 4.5))
    chain_ids = sorted({r["chain_id"] for r in migrate_rows})
    cmap = plt.get_cmap("tab10")
    for i, chain_id in enumerate(chain_ids):
        chain_rows = [r for r in migrate_rows if r["chain_id"] == chain_id]
        ax.plot(
            [r["ts"] for r in chain_rows], [r["duration_ms"] for r in chain_rows],
            marker="o", markersize=3, linewidth=0.8, alpha=0.7,
            color=cmap(i % 10), label=f"chain {chain_id[:8]}",
        )
    ax.axvline(trigger_s, color="red", linestyle="--", linewidth=1.5, label="migration triggered")

    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("Per-block confirmation latency (ms)")
    ax.set_title("Handover timeline: migrated chains")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.legend(loc="upper right", frameon=True, fontsize=7, ncol=2)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)

    fig.tight_layout()
    fig.savefig(f"{output_prefix}_timeline.png", dpi=200)
    fig.savefig(f"{output_prefix}_timeline.pdf")
    print(f"Wrote {output_prefix}_timeline.png and .pdf")


def percentile(sorted_values, p):
    idx = min(len(sorted_values) - 1, max(0, round(p / 100 * (len(sorted_values) - 1))))
    return sorted_values[idx]


def plot_cdf(rows, output_prefix, selection_note):
    fig, ax = plt.subplots(figsize=(7, 4.8))
    all_vals = []
    stats = {}
    for group, color in [("control", "tab:blue"), ("migrate", "tab:red")]:
        values = sorted(r["duration_ms"] for r in rows if r["group"] == group)
        if not values:
            continue
        all_vals.extend(values)
        n = len(values)
        ys = [(i + 1) / n for i in range(n)]
        ax.plot(values, ys, color=color, linewidth=1.5, label=f"{group} (n={n})")
        stats[group] = {
            p: percentile(values, p) for p in (50, 90, 95, 99)
        }
    ax.legend(loc="upper right", frameon=True)

    # Clip to where the data actually lives, not an arbitrary 0 origin -- a 1ms tail
    # difference is invisible if the axis wastes most of its width below the first block.
    lo = max(0, percentile(sorted(all_vals), 1) - 0.5)
    hi = percentile(sorted(all_vals), 99.5) + 0.5
    ax.set_xlim(lo, hi)

    ax.set_xlabel("Per-block confirmation latency (ms)")
    ax.set_ylabel("CDF")
    ax.set_title("Per-block latency: migrated vs. control chains (whole run)")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.set_ylim(0, 1)

    if "control" in stats and "migrate" in stats:
        text = (
            f"median: {stats['control'][50]:.2f} vs {stats['migrate'][50]:.2f} ms\n"
            f"p90: {stats['control'][90]:.2f} vs {stats['migrate'][90]:.2f} ms\n"
            f"p95: {stats['control'][95]:.2f} vs {stats['migrate'][95]:.2f} ms"
        )
        ax.text(
            0.03, 0.7, text, transform=ax.transAxes, fontsize=8,
            verticalalignment="top", bbox=dict(boxstyle="round", facecolor="white", alpha=0.85),
        )

    # CCDF on log-y as an inset: the tail gap is the whole point of this figure and a
    # linear CDF crams it into the top few percent near y=1 where it's hard to read.
    inset = ax.inset_axes([0.53, 0.1, 0.42, 0.4])
    for group, color in [("control", "tab:blue"), ("migrate", "tab:red")]:
        values = sorted(r["duration_ms"] for r in rows if r["group"] == group)
        if not values:
            continue
        n = len(values)
        ccdf = [1 - (i + 1) / n for i in range(n)]
        inset.plot(values, ccdf, color=color, linewidth=1.0)
    inset.set_yscale("log")
    inset.set_xlim(lo, hi)
    inset.set_xlabel("latency (ms)", fontsize=7)
    inset.set_ylabel("CCDF (log)", fontsize=7)
    inset.tick_params(labelsize=6)
    inset.grid(True, linestyle=":", linewidth=0.4, alpha=0.6)

    if selection_note:
        wrapped = "\n".join(textwrap.wrap(selection_note, width=110))
        fig.text(0.01, 0.01, wrapped, fontsize=6.5, color="dimgray")
        fig.subplots_adjust(bottom=0.18)

    fig.tight_layout(rect=(0, 0.08, 1, 1))
    fig.savefig(f"{output_prefix}_cdf.png", dpi=200)
    fig.savefig(f"{output_prefix}_cdf.pdf")
    print(f"Wrote {output_prefix}_cdf.png and .pdf")
    for group, s in stats.items():
        print(f"  {group}: " + " ".join(f"p{p}={v:.2f}ms" for p, v in s.items()))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    out_dir = Path(sys.argv[1])
    output_prefix = sys.argv[2] if len(sys.argv) > 2 else str(out_dir / "migration_cost")

    rows = read_tagged_transfers(out_dir / "tagged_transfers.csv")
    if not rows:
        print("No committed rows found in", out_dir / "tagged_transfers.csv")
        sys.exit(1)
    trigger_s = read_migration_trigger(out_dir)

    migrations = list(csv.DictReader(open(out_dir / "migrations.csv")))
    from_shards = sorted({m["from_shard"] for m in migrations})
    selection_note = (
        f"Selection: {len(migrations)} chains chosen by provisioning order (not load), "
        f"migrated under identical offered load from t=0; source shards {{{', '.join(from_shards)}}} "
        f"-- not concentrated on one worker."
    )

    plot_timeline(rows, trigger_s, output_prefix)
    plot_cdf(rows, output_prefix, selection_note)


if __name__ == "__main__":
    main()
