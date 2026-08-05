#!/usr/bin/env python3
"""Diffs two directories of Prometheus /metrics text dumps (one file per shard/proxy port)
and reports where cumulative time/CPU went during the window between the snapshots.

Usage: analyze_metrics_snapshot.py <before_dir> <after_dir> <elapsed_seconds>
"""
import glob
import os
import re
import sys
from collections import defaultdict

LABEL_RE = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')


def parse_file(path):
    """Returns {(metric_name, (('label', 'value'), ...)): value}."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "{" in line:
                name, rest = line.split("{", 1)
                labels_str, value_str = rest.rsplit("}", 1)
                labels = tuple(sorted(LABEL_RE.findall(labels_str)))
            else:
                name, value_str = line.rsplit(" ", 1)
                labels = ()
            try:
                value = float(value_str.strip())
            except ValueError:
                continue
            out[(name, labels)] = out.get((name, labels), 0.0) + value
    return out


def aggregate_dir(directory):
    """Sums metric values across every port file in the directory (one per shard/proxy)."""
    combined = defaultdict(float)
    per_file_worker_counts = []
    for path in sorted(glob.glob(os.path.join(directory, "*.txt"))):
        parsed = parse_file(path)
        for key, value in parsed.items():
            combined[key] += value
        for (name, labels), value in parsed.items():
            if name == "linera_tokio_workers":
                per_file_worker_counts.append(value)
    return combined, per_file_worker_counts


def label_value(labels, key):
    for k, v in labels:
        if k == key:
            return v
    return None


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    before_dir, after_dir, elapsed = sys.argv[1], sys.argv[2], float(sys.argv[3])

    before, before_workers = aggregate_dir(before_dir)
    after, after_workers = aggregate_dir(after_dir)

    delta = defaultdict(float)
    for key in set(before) | set(after):
        delta[key] = after.get(key, 0.0) - before.get(key, 0.0)

    print("=" * 78)
    print(f"Metrics diff over {elapsed:.0f}s ({os.path.basename(before_dir)} -> {os.path.basename(after_dir)})")
    print("=" * 78)

    # --- Tokio runtime: real CPU time spent executing async tasks, per process ---
    total_busy = sum(v for (n, _), v in delta.items() if n == "linera_tokio_worker_busy_seconds_total")
    total_workers = sum(after_workers)
    print("\n-- Tokio runtime (async task CPU time) --")
    if total_workers > 0:
        capacity_seconds = total_workers * elapsed
        util_pct = 100.0 * total_busy / capacity_seconds if capacity_seconds else 0.0
        print(f"  total worker-threads across all shards+proxy : {total_workers:.0f}")
        print(f"  total busy time (sum over all workers)        : {total_busy:.1f}s")
        print(f"  aggregate utilization (busy / (workers*elapsed)): {util_pct:.1f}%")
        print("  -> low utilization means CPU is mostly idle/parked (bottleneck is elsewhere,")
        print("     e.g. network/locking/serialization); high utilization means the async")
        print("     tasks themselves are the CPU sink (see request/storage breakdown below).")
    else:
        print("  no linera_tokio_workers samples found -- were both snapshots taken while the node was up?")

    parks = sum(v for (n, _), v in delta.items() if n == "linera_tokio_worker_parks_total")
    print(f"  total park events (worker ran out of work)     : {parks:.0f}")

    # --- Per-RPC-method latency/volume: linera_server_request_latency (shards) and
    # linera_proxy_request_latency (proxy), both in ms, both labeled by method_name ---
    print("\n-- RPC latency by method, ms (linera_server_request_latency + linera_proxy_request_latency) --")
    method_sum = defaultdict(float)
    method_count = defaultdict(float)
    for (name, labels), value in delta.items():
        if name not in ("linera_server_request_latency_sum", "linera_proxy_request_latency_sum",
                        "linera_server_request_latency_count", "linera_proxy_request_latency_count"):
            continue
        method = label_value(labels, "method_name") or "?"
        source = "server" if "server" in name else "proxy"
        key = (source, method)
        if name.endswith("_sum"):
            method_sum[key] += value
        else:
            method_count[key] += value
    rows = []
    for key, total_ms in method_sum.items():
        count = method_count.get(key, 0.0)
        avg_ms = total_ms / count if count else 0.0
        rows.append((total_ms, key, count, avg_ms))
    rows.sort(reverse=True)
    if rows:
        print(f"  {'source':<8} {'method':<28} {'calls':>10} {'total_ms':>12} {'avg_ms':>10}")
        for total_ms, (source, method), count, avg_ms in rows:
            print(f"  {source:<8} {method:<28} {count:>10.0f} {total_ms:>12.1f} {avg_ms:>10.2f}")
    else:
        print("  (no samples -- is the proxy/shard gRPC server actually receiving traffic?)")

    # --- All other histograms, split into real latency (ms, actionable as "time spent")
    # vs. size/byte histograms (NOT time -- reported separately so they can't be
    # mistaken for time-cost, since prometheus's *_sum/*_count naming is identical for both) ---
    seen_prefixes = {"linera_server_request_latency", "linera_proxy_request_latency"}
    # These call `.measure_latency_us()` (linera-base/src/prometheus_util.rs) instead of the
    # otherwise-universal `.measure_latency()` (milliseconds) -- confirmed by reading each
    # call site directly (linera-chain/src/chain.rs:846,1190, linera-chain/src/block_tracker.rs:
    # 171,254), since the HELP text alone doesn't reliably state the unit. Getting this wrong
    # previously produced a 1000x-inflated "cumulative time" for block_execution_latency.
    microsecond_metrics = {
        "linera_state_hash_computation_latency",
        "linera_block_execution_latency",
        "linera_operation_execution_latency",
        "linera_message_execution_latency",
    }
    sums = defaultdict(float)
    counts = defaultdict(float)
    for (name, labels), value in delta.items():
        if name.endswith("_sum"):
            base = name[: -len("_sum")]
            if base in seen_prefixes:
                continue
            sums[(base, labels)] += value
        elif name.endswith("_count"):
            base = name[: -len("_count")]
            if base in seen_prefixes:
                continue
            counts[(base, labels)] += value

    latency_rows, size_rows = [], []
    for key, total in sums.items():
        base, labels = key
        count = counts.get(key, 0.0)
        avg = total / count if count else 0.0
        label_str = ",".join(f"{k}={v}" for k, v in labels) or "-"
        if "latency" in base:
            if base in microsecond_metrics:
                total, avg = total / 1000.0, avg / 1000.0  # normalize to ms
            latency_rows.append((total, base, label_str, count, avg))
        else:
            size_rows.append((total, base, label_str, count, avg))

    print("\n-- Other latency histograms: cumulative time by operation, ms (top 15) --")
    latency_rows.sort(reverse=True)
    if latency_rows:
        print(f"  {'metric':<40} {'labels':<24} {'count':>10} {'total_ms':>12} {'avg_ms':>10}")
        for total, base, label_str, count, avg in latency_rows[:15]:
            print(f"  {base:<40} {label_str:<24} {count:>10.0f} {total:>12.1f} {avg:>10.3f}")
    else:
        print("  (none)")

    print("\n-- Size/byte histograms (NOT time -- data volume, top 10) --")
    size_rows.sort(reverse=True)
    if size_rows:
        print(f"  {'metric':<40} {'labels':<24} {'count':>10} {'total_bytes':>14} {'avg_bytes':>10}")
        for total, base, label_str, count, avg in size_rows[:10]:
            print(f"  {base:<40} {label_str:<24} {count:>10.0f} {total:>14.0f} {avg:>10.1f}")
    else:
        print("  (none)")

    # --- Top-line throughput counters ---
    print("\n-- Chain-processing counters (delta) --")
    for wanted in ["linera_num_blocks", "linera_num_blocks_executed", "linera_transaction_count",
                   "linera_operation_count", "linera_incoming_message_count", "linera_certificates_signed"]:
        total = sum(v for (n, _), v in delta.items() if n == wanted)
        print(f"  {wanted:<32} {total:>12.0f}")


if __name__ == "__main__":
    main()
