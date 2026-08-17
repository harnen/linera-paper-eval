#!/usr/bin/env python3
"""Builds the 3-panel migration-cost figure:
  (a) Handover duration CDF: small-state vs. large-state chains (from
      run_state_size_experiment.sh's OUT_DIR).
  (b) Event-aligned per-block latency: median + p95 across every migration observed, x-axis
      is block index relative to the migration trigger (from
      run_repeated_migration_experiment.sh's OUT_DIR). Block index 0 is the first block
      committed at or after the trigger, not the precise lock-acquire instant -- see that
      script's header comment for why the two are close but not identical at this block rate.
  (c) Whole-run CDF: migrated vs. control chains (from run_migration_cost_experiment.sh's
      OUT_DIR), selection method stated in the caption.

Usage: plot_migration_figure2.py <state_size_dir> <repeated_migration_dir> <migration_cost_dir> [output_prefix]
"""
import csv
import statistics
import sys
import textwrap
from pathlib import Path

import matplotlib.pyplot as plt


def percentile(sorted_values, p):
    if not sorted_values:
        return float("nan")
    idx = min(len(sorted_values) - 1, max(0, round(p / 100 * (len(sorted_values) - 1))))
    return sorted_values[idx]


# ---------- Panel (a): handover duration CDF, small vs large state ----------

def read_durations(path):
    vals = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if row.get("duration_ms"):
                vals.append(float(row["duration_ms"]))
    return sorted(vals)


def plot_panel_a(ax, state_size_dir):
    small = read_durations(state_size_dir / "small_durations.csv")
    large = read_durations(state_size_dir / "large_durations.csv")
    for label, vals, color in [("small state", small, "tab:blue"), ("large state", large, "tab:red")]:
        if not vals:
            continue
        n = len(vals)
        ys = [(i + 1) / n for i in range(n)]
        ax.plot(vals, ys, color=color, linewidth=1.5, label=f"{label} (n={n})")
    ax.set_xlabel("Handover duration: decision → acquired (ms)")
    ax.set_ylabel("CDF")
    ax.set_title("(a) Handover duration vs. state size")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.legend(loc="lower right", frameon=True, fontsize=8)
    ax.set_ylim(0, 1)
    if small and large:
        print(
            f"  (a) small state: median={statistics.median(small):.3f}ms "
            f"p95={percentile(small,95):.3f}ms  |  "
            f"large state: median={statistics.median(large):.3f}ms "
            f"p95={percentile(large,95):.3f}ms"
        )


# ---------- Panel (b): event-aligned per-block latency ----------

def event_aligned_stats(repeated_dir, window=10):
    """Returns (offsets, medians, p95s, n_events, n_triggered, floor_ms, in_flight_frac) for
    one run_repeated_migration_experiment.sh OUT_DIR.

    Aligns on h_star_elapsed_seconds (the "acquired chain" tracing line's own timestamp --
    the actual write-lock handover completing) when present, falling back to elapsed_seconds
    (the ssh dispatch trigger) for older data that predates the h* capture. The two differ by
    the handover duration itself (median ~17ms, but with a tail -- see
    run_state_size_experiment.sh), so aligning on the trigger smears a real spike across
    several block indices at these block rates.

    in_flight_frac is the fraction of migrations where a committed block's own processing
    window [ts - duration, ts] overlapped [trigger, h_star] -- i.e. a proposal was genuinely
    in flight while the lock changed hands, not just "the nearest block was close in time".
    """
    transfers = list(csv.DictReader(open(repeated_dir / "transfers.csv", newline="")))
    transfers = [r for r in transfers if r["result"] == "committed"]
    by_chain = {}
    for r in transfers:
        ts = float(r["ts_within_experiment"])
        dur_ms = float(r["duration_micros"]) / 1000.0
        by_chain.setdefault(r["chain_id"], []).append((ts, dur_ms))
    for chain_id in by_chain:
        by_chain[chain_id].sort(key=lambda t: t[0])

    migrations = list(csv.DictReader(open(repeated_dir / "migrations.csv", newline="")))
    has_h_star = bool(migrations) and "h_star_elapsed_seconds" in migrations[0]

    by_offset = {off: [] for off in range(-window, window + 1)}
    n_events = 0
    n_in_flight = 0
    for m in migrations:
        chain_id = m["chain_id"]
        trigger = float(m["elapsed_seconds"])
        h_star = float(m["h_star_elapsed_seconds"]) if has_h_star else trigger
        rows = by_chain.get(chain_id)
        if not rows:
            continue
        i_star = next((i for i, (ts, _) in enumerate(rows) if ts >= h_star), None)
        if i_star is None:
            continue
        n_events += 1
        for off in range(-window, window + 1):
            idx = i_star + off
            if 0 <= idx < len(rows):
                by_offset[off].append(rows[idx][1])
        if any((ts - dur_ms / 1000.0) <= h_star and ts >= trigger for ts, dur_ms in rows):
            n_in_flight += 1

    offsets = sorted(by_offset)
    medians = [statistics.median(by_offset[o]) if by_offset[o] else float("nan") for o in offsets]
    p95s = [percentile(sorted(by_offset[o]), 95) if by_offset[o] else float("nan") for o in offsets]

    all_gaps = []
    for rows in by_chain.values():
        for (t0, _), (t1, _) in zip(rows, rows[1:]):
            all_gaps.append((t1 - t0) * 1000.0)
    floor_ms = statistics.median(all_gaps) if all_gaps else float("nan")
    in_flight_frac = n_in_flight / n_events if n_events else float("nan")

    return offsets, medians, p95s, n_events, len(migrations), floor_ms, in_flight_frac


def plot_panel_b(ax, repeated_dirs, window=10):
    """repeated_dirs: list of (label, Path) pairs, one per bps rate tested -- e.g. the
    original ~50ms-spacing run alongside a higher-rate run whose inter-block gap is below
    the measured handover duration (panel (a)), so a straddling block is likely for every
    migration instead of a minority of them."""
    colors = ["tab:blue", "tab:orange", "tab:green"]
    all_medians_p95s = []
    floor_notes = []
    for i, (label, repeated_dir) in enumerate(repeated_dirs):
        offsets, medians, p95s, n_events, n_triggered, floor_ms, in_flight_frac = event_aligned_stats(
            repeated_dir, window
        )
        color = colors[i % len(colors)]
        ax.plot(offsets, medians, color=color, marker="o", markersize=3, linewidth=1.3,
                 label=f"{label} median (n={n_events})")
        ax.plot(offsets, p95s, color=color, marker="^", markersize=3, linewidth=1.0,
                 linestyle="--", alpha=0.7, label=f"{label} p95")
        all_medians_p95s.extend(medians)
        all_medians_p95s.extend(p95s)
        floor_notes.append(f"{label}: floor≈{floor_ms:.0f}ms")
        print(
            f"  (b) [{label}] {n_events} migration events, {n_triggered} triggered; "
            f"detection floor ≈ {floor_ms:.1f}ms; proposal in flight during handover in "
            f"{100*in_flight_frac:.1f}% of events"
        )

    ax.axvline(0, color="gray", linestyle=":", linewidth=1.0)
    ax.set_xlabel("Block index relative to migration trigger")
    ax.set_ylabel("Per-block confirmation latency (ms)")
    ax.set_title("(b) Event-aligned latency, by block rate")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.legend(loc="upper right", frameon=True, fontsize=7)
    finite_vals = [v for v in all_medians_p95s if v == v]
    if finite_vals:
        lo, hi = min(finite_vals), max(finite_vals)
        pad = max(0.2, (hi - lo) * 0.2)
        ax.set_ylim(max(0, lo - pad), hi + pad)
    ax.text(
        0.02, 0.02, " | ".join(floor_notes),
        transform=ax.transAxes, fontsize=7, color="dimgray",
    )


# ---------- Panel (c): whole-run CDF, within-chain before vs. after migration ----------
#
# Uses only the "migrate" group, split at the single shared migration_trigger_elapsed_seconds
# (every migrate-group chain is migrated simultaneously at that instant -- see
# run_migration_cost_experiment.sh). This is a within-chain before/after comparison, not
# control-vs-migrate across different chains, so chain identity cannot be a confound.

def plot_panel_c(ax, migration_cost_dir):
    rows = list(csv.DictReader(open(migration_cost_dir / "tagged_transfers.csv", newline="")))
    rows = [r for r in rows if r["result"] == "committed" and r["group"] == "migrate"]
    trigger = float(
        next(csv.DictReader(open(migration_cost_dir / "migration_trigger.csv", newline="")))[
            "migration_trigger_elapsed_seconds"
        ]
    )
    migrations = list(csv.DictReader(open(migration_cost_dir / "migrations.csv", newline="")))

    stats = {}
    for phase, color in [("before", "tab:blue"), ("after", "tab:red")]:
        vals = sorted(
            float(r["duration_micros"]) / 1000.0
            for r in rows
            if (float(r["ts_within_experiment"]) < trigger) == (phase == "before")
        )
        if not vals:
            continue
        n = len(vals)
        ys = [(i + 1) / n for i in range(n)]
        ax.plot(vals, ys, color=color, linewidth=1.5, label=f"{phase} (n={n})")
        stats[phase] = {p: percentile(vals, p) for p in (50, 90, 95)}

    all_vals = sorted(float(r["duration_micros"]) / 1000.0 for r in rows)
    lo = max(0, percentile(all_vals, 1) - 0.5)
    hi = percentile(all_vals, 99.5) + 0.5
    ax.set_xlim(lo, hi)
    ax.set_xlabel("Per-block confirmation latency (ms)")
    ax.set_ylabel("CDF")
    ax.set_title("(c) Migrated chains: within-chain before vs. after")
    ax.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax.legend(loc="lower right", frameon=True, fontsize=8)
    ax.set_ylim(0, 1)

    if "before" in stats and "after" in stats:
        note = (
            f"Within-chain: {len(migrations)} chains migrated simultaneously at "
            f"t={trigger:.1f}s; before/after split on the same chains, not control-vs-migrate."
        )
        ax.text(
            0.02, 0.72,
            f"median: {stats['before'][50]:.2f} vs {stats['after'][50]:.2f} ms\n"
            f"p95: {stats['before'][95]:.2f} vs {stats['after'][95]:.2f} ms",
            transform=ax.transAxes, fontsize=7,
            verticalalignment="top", bbox=dict(boxstyle="round", facecolor="white", alpha=0.85),
        )
        print(f"  (c) {note}")
        print(
            f"      median: before={stats['before'][50]:.3f}ms after={stats['after'][50]:.3f}ms | "
            f"p95: before={stats['before'][95]:.3f}ms after={stats['after'][95]:.3f}ms"
        )
        return note
    return ""


def main():
    import argparse

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("state_size_dir", type=Path)
    parser.add_argument(
        "repeated_dir", type=str,
        help="one or more label=path pairs, comma-separated, e.g. "
        "'50ms=results/repeated_migration/run_A,15ms=results/repeated_migration/run_B'",
    )
    parser.add_argument("migration_cost_dir", type=Path)
    parser.add_argument("output_prefix", nargs="?", default="migration_figure2")
    args = parser.parse_args()

    repeated_dirs = []
    for pair in args.repeated_dir.split(","):
        label, _, path = pair.partition("=")
        repeated_dirs.append((label, Path(path)))

    fig, axes = plt.subplots(1, 3, figsize=(16, 4.8))
    plot_panel_a(axes[0], args.state_size_dir)
    plot_panel_b(axes[1], repeated_dirs)
    note = plot_panel_c(axes[2], args.migration_cost_dir)
    output_prefix = args.output_prefix

    if note:
        wrapped = "\n".join(textwrap.wrap(note, width=140))
        fig.text(0.01, 0.01, wrapped, fontsize=6.5, color="dimgray")
        fig.subplots_adjust(bottom=0.16)
        fig.tight_layout(rect=(0, 0.08, 1, 1))
    else:
        fig.tight_layout()

    fig.savefig(f"{output_prefix}.png", dpi=200)
    fig.savefig(f"{output_prefix}.pdf")
    print(f"Wrote {output_prefix}.png and .pdf")


if __name__ == "__main__":
    main()
