#!/usr/bin/env python3
"""Plots the elasticity experiment (paper Fig. 6): requested/achieved workload (bps),
latency, and active shard (worker) count, all over time on a shared x-axis. Worker count
comes from parsing linera-service/src/manager.rs's own `info!` log lines (no separate
tracking needed -- the manager already logs every spawn/drain).

Usage: plot_elasticity.py <experiment_dir> [output_path]
  experiment_dir must contain combined_transfers.csv, manager.log, metadata.txt,
  experiment_start_epoch.txt, sparta_clock_offset_seconds.txt (all written by
  run_elasticity_experiment.sh).
  output_path defaults to <experiment_dir>/elasticity.png
"""
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import matplotlib.pyplot as plt

LOG_LINE_RE = re.compile(
    r"^(?P<ts>\S+Z)\s+INFO\s+linera_service::manager:\s+(?P<msg>starting elastic worker|"
    r"elastic worker is ready|draining elastic worker|elastic worker stopped)\s+shard=(?P<shard>\d+)"
)


def read_metadata(path):
    meta = {}
    with open(path) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                meta[k] = v
    return meta


def parse_bps_schedule(spec):
    """Parses "offset:bps,offset:bps,..." into a sorted [(offset, bps), ...]."""
    breakpoints = []
    for part in spec.split(","):
        offset_str, bps_str = part.split(":")
        breakpoints.append((float(offset_str), float(bps_str)))
    breakpoints.sort()
    return breakpoints


def schedule_step_series(breakpoints, end_time):
    """Turns schedule breakpoints into a step function (x, y) suitable for plt.step."""
    xs, ys = [], []
    for offset, bps in breakpoints:
        xs.append(offset)
        ys.append(bps)
    xs.append(end_time)
    ys.append(ys[-1] if ys else 0)
    return xs, ys


def parse_manager_log(path, clock_offset, experiment_start_epoch):
    """Returns a sorted list of (elapsed_seconds, delta) where delta is +1 for a worker
    becoming ready and -1 for a worker being confirmed stopped."""
    events = []
    with open(path) as f:
        for line in f:
            m = LOG_LINE_RE.match(line)
            if not m:
                continue
            msg = m.group("msg")
            if msg not in ("elastic worker is ready", "elastic worker stopped"):
                continue
            ts = datetime.strptime(m.group("ts"), "%Y-%m-%dT%H:%M:%S.%fZ").replace(
                tzinfo=timezone.utc
            )
            epoch = ts.timestamp()
            local_equivalent_epoch = epoch - clock_offset
            elapsed = local_equivalent_epoch - experiment_start_epoch
            delta = 1 if msg == "elastic worker is ready" else -1
            events.append((elapsed, delta))
    events.sort()
    return events


def build_worker_count_series(events, base_shards, end_time):
    """Turns +1/-1 events into a step function (x, y) suitable for plt.step."""
    xs = [0.0]
    ys = [base_shards]
    count = base_shards
    for elapsed, delta in events:
        xs.append(elapsed)
        ys.append(count)
        count += delta
        xs.append(elapsed)
        ys.append(count)
    xs.append(end_time)
    ys.append(count)
    return xs, ys


def read_transfers(transfers_path):
    """Returns a sorted list of (ts_within_experiment, duration_ms, committed: bool)."""
    rows = []
    with open(transfers_path) as f:
        next(f, None)
        for line in f:
            chain_id, ts, num_tx, result, duration_micros = line.rstrip("\n").split(",")
            rows.append((float(ts), float(duration_micros) / 1000.0, result == "committed"))
    rows.sort()
    return rows


def bucket_latency(rows, bucket_seconds):
    committed = [(ts, dur) for ts, dur, ok in rows if ok]
    if not committed:
        return [], [], [], []
    max_t = committed[-1][0]
    num_buckets = int(max_t // bucket_seconds) + 1
    buckets = [[] for _ in range(num_buckets)]
    for ts, dur_ms in committed:
        idx = min(int(ts // bucket_seconds), num_buckets - 1)
        buckets[idx].append(dur_ms)

    centers, p50s, p25s, p95s = [], [], [], []
    for i, durs in enumerate(buckets):
        if not durs:
            continue
        durs.sort()

        def pct(p):
            idx = min(len(durs) - 1, max(0, int(p / 100 * len(durs))))
            return durs[idx]

        centers.append(i * bucket_seconds + bucket_seconds / 2)
        p25s.append(pct(25))
        p50s.append(pct(50))
        p95s.append(pct(95))
    return centers, p25s, p50s, p95s


def bucket_achieved_bps(rows, bucket_seconds):
    if not rows:
        return [], []
    max_t = rows[-1][0]
    num_buckets = int(max_t // bucket_seconds) + 1
    counts = [0] * num_buckets
    for ts, _dur, ok in rows:
        if not ok:
            continue
        idx = min(int(ts // bucket_seconds), num_buckets - 1)
        counts[idx] += 1
    centers = [i * bucket_seconds + bucket_seconds / 2 for i in range(num_buckets)]
    bps = [c / bucket_seconds for c in counts]
    return centers, bps


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    exp_dir = Path(sys.argv[1])
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else exp_dir / "elasticity.png"

    meta = read_metadata(exp_dir / "metadata.txt")
    base_shards = int(meta["base_shards"])
    schedule = parse_bps_schedule(meta["bps_schedule"])

    clock_offset = float((exp_dir / "sparta_clock_offset_seconds.txt").read_text().strip())
    experiment_start_epoch = float((exp_dir / "experiment_start_epoch.txt").read_text().strip())

    rows = read_transfers(exp_dir / "combined_transfers.csv")
    bucket_seconds = 3.0
    lat_centers, p25s, p50s, p95s = bucket_latency(rows, bucket_seconds)
    bps_centers, achieved_bps = bucket_achieved_bps(rows, bucket_seconds)

    events = parse_manager_log(exp_dir / "manager.log", clock_offset, experiment_start_epoch)
    # The manager keeps logging scale events for a few seconds after traffic itself stops
    # (draining takes a moment), so end_time must cover whichever data source runs latest --
    # using only the transfers' own last timestamp here previously left the final worker-count
    # point earlier on the x-axis than the last actual event, drawing the step plot's last
    # segment backwards.
    end_time = max(
        [lat_centers[-1] if lat_centers else 0.0, schedule[-1][0]]
        + [elapsed for elapsed, _ in events]
    )
    worker_xs, worker_ys = build_worker_count_series(events, base_shards, end_time)
    sched_xs, sched_ys = schedule_step_series(schedule, end_time)

    fig, (ax_bps, ax_latency, ax_workers) = plt.subplots(
        3, 1, figsize=(10, 8), sharex=True, gridspec_kw={"height_ratios": [1.3, 1.7, 1]}
    )

    ax_bps.step(sched_xs, sched_ys, where="post", color="gray", linewidth=1.2,
                linestyle="--", label="requested (schedule)")
    ax_bps.plot(bps_centers, achieved_bps, color="tab:green", linewidth=1.2, label="achieved")
    ax_bps.set_ylabel("Blocks/s")
    ax_bps.legend(loc="upper left", fontsize=8, frameon=True)
    ax_bps.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)

    yerr_lower = [max(0.0, m - lo) for m, lo in zip(p50s, p25s)]
    yerr_upper = [max(0.0, hi - m) for m, hi in zip(p50s, p95s)]
    ax_latency.errorbar(
        lat_centers, p50s, yerr=[yerr_lower, yerr_upper],
        marker="o", markersize=2.5, color="tab:blue", linewidth=1, capsize=1.5, elinewidth=0.6,
    )
    ax_latency.set_ylabel("Latency (ms)")
    ax_latency.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)

    ax_workers.step(worker_xs, worker_ys, where="post", color="tab:red", linewidth=1.5)
    ax_workers.set_ylabel("Active shards")
    ax_workers.set_xlabel("Elapsed time (s)")
    ax_workers.grid(True, linestyle=":", linewidth=0.6, alpha=0.7)
    ax_workers.set_ylim(bottom=0)

    fig.tight_layout()
    fig.savefig(output_path, dpi=200)
    fig.savefig(output_path.with_suffix(".pdf"))
    print(f"Wrote {output_path} and {output_path.with_suffix('.pdf')}")
    print(f"Manager events parsed: {len(events)}")


if __name__ == "__main__":
    main()
