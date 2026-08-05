# Handover note — Linera throughput evaluation

Written 2026-08-05. Covers everything done this session: restoring/merging the dynamic-sharding
work, building a bare-metal (no Docker) benchmark harness against two real machines, a max-TPS-
vs-worker-count sweep, an elasticity (auto-scaling) experiment, and a storage-layer lock-
contention investigation.

## 0. Read this first

- **`linera-protocol`, branch `light_client`**: fully committed and pushed as of this note,
  including `linera-rpc/src/routing.rs` and `linera-service/src/manager.rs` (were referenced
  by an earlier commit but never actually committed — fixed, branch compiles from a fresh
  clone) and the storage-layer `crossbeam-skiplist` rewrite (section 1.3, commit
  `fbb2c4c3ab`). Nothing outstanding on this repo.
- **`linera-paper-eval` (this repo)**: all the scripts built this session were untracked until
  now. They're committed to a new branch, **`michal`**, but **I could not push it** — no
  write access to `github.com/mrd0ll4r/linera-paper-eval` from this machine (checked both
  HTTPS and SSH). Someone with push access needs to run `git push -u origin michal` from
  `/home/harnen/work/linera/linera-paper-eval`, or the commit needs to be moved to wherever
  you'd normally push from. Until that happens, this repo's `master` branch has none of this
  session's scripts.
- Everything below assumes you're on that `michal` branch.

## 1. Code changes

### 1.1 Light client (`linera-lite-benchmark`)

Pre-existing tool (predates this session), extended here. File:
`linera-protocol/linera-service/src/lite_benchmark.rs`.

- Added `--bps-schedule "offset:bps,offset:bps,..."`: a time-varying target rate instead of a
  fixed `--bps`, for the elasticity experiment. Must start at offset 0. A background task polls
  every 200ms and updates a shared `Arc<AtomicUsize>`; each chain's task recomputes its own
  share every tick and rebuilds its `tokio::time::interval` only when the rate actually changes.
- **Bug fixed**: the per-chain rate was computed as `current_bps / num_chains` using **integer**
  division. With many chains and a low aggregate rate (e.g. 9 total ÷ 10 chains on one client),
  this truncates to exactly 0 — not "sparse traffic", but **permanently zero** traffic for that
  chain until the schedule moves to a high-enough rate again. Fixed by switching to `f64`
  division. See section 3.1 for the debugging story; this bug class (integer division silently
  zeroing a low-but-nonzero rate) also existed in the bash-side pre-division in
  `run_lite_benchmark_parallel.sh` and was fixed there too (floor → ceiling rounding).

### 1.2 Dynamic sharding (elastic worker pool)

Restored from a separate, incomplete branch + an old stash (see git log on `light_client`:
merge commit `8eb7a430ba`, "next iteration" `bfc63d6a34`, plus the `routing.rs`/`manager.rs`
commit added at the end of this session). Now fully committed and pushed.

Key pieces, all in `linera-protocol`:
- **`linera-rpc/src/routing.rs`** — `ShardRouter`: a dynamic chain→shard routing table.
  Default assignment is a public-key-seeded hash over the validator's `base_shards` slots;
  individual chains can be migrated to any shard at runtime. Acts as a handover barrier: a
  request handler holds a read guard on its chain's routing entry for the duration of
  processing, so a migration (which takes the write guard) waits for in-flight requests to
  finish before flipping ownership.
- **`linera-service/src/manager.rs`** — `linera-server manager`: a real, unit-tested (8 tests),
  threshold-with-hysteresis auto-scaler. Scales up an elastic worker when a shard exceeds
  `--high-watermark` req/s and no shard has spare capacity; greedily rebalances the hottest
  chain to the least-loaded shard only if it strictly reduces imbalance (anti-ping-pong); scales
  down idle elastic workers after `--scale-down-rounds` consecutive quiet polls; a
  `--cooldown-rounds` pause after every scale event. With `--spawn-command`, it starts/stops
  elastic workers as its own child processes.
- **`ValidatorInternalNetworkConfig::base_shards`** (`linera-rpc/src/config.rs`) — shards beyond
  this prefix are "elastic": they only ever own explicitly-migrated chains, so killing one is
  always safe (never orphans a chain that still hash-routes there by default).
- **`GetLoadReport`/`ListShardAssignments` RPCs** (`linera-rpc/proto/rpc.proto`,
  `linera-rpc/src/grpc/server.rs`) — per-chain request counters
  (`Arc<papaya::HashMap<ChainId, AtomicU64>>`), incremented on every locally-routed request,
  drained each manager poll. This is the manager's real load signal, not a proxy-side proxy
  metric.
- CLI: `linera-server manager --server <config> [--interval-ms 2000] [--high-watermark 500.0]
  [--low-watermark high/4] [--max-migrations-per-round 8] [--scale-down-rounds 5]
  [--cooldown-rounds 3] [--spawn-command "..."]`.

**Known cost**: every request (on shards *and* the proxy) now goes through
`router.shard_for()`/`read_guard()` — an async `RwLock` read plus a `papaya::HashMap` lookup —
instead of a plain synchronous hash computation. This is real, measured overhead (see section
3.2), separate from anything storage-related.

### 1.3 Storage layer (`MemoryStore`) — tested, kept, **not yet committed**

File: `linera-protocol/linera-views/src/backends/memory.rs`.

Original design: one `Arc<std::sync::RwLock<BTreeMap<Vec<u8>, Vec<u8>>>>` per chain. Every read
takes a shared lock, every `write_batch` takes an exclusive lock over the *whole chain's*
keyspace — so one chain's writes block all its own concurrent reads.

- **Tried and reverted**: swapping to `parking_lot::RwLock`/`Mutex` (same coarse-lock
  structure, just a different lock implementation). Under real contention (~45k tx/s) this made
  things **3-4x worse**, not better — `parking_lot`'s optimistic spin-then-park strategy burns
  CPU cycles under *sustained* high contention with far more threads than cores (this system
  runs ~800 Tokio worker threads across 19 shards + proxy on a 40-core box), worsening a
  thundering-herd effect instead of helping. Reverted via `git checkout --`.
- **Kept**: rewrote `MemoryStore` to use `crossbeam_skiplist::SkipMap<Vec<u8>, Vec<u8>>` — a
  lock-free, sorted, concurrent map. No lock at all now; reads/writes/range-scans on different
  keys never contend. Added `crossbeam-skiplist = "0.1"` (resolves to 0.1.3) as a new workspace
  dependency.
  - **Correctness note, documented in a comment in the file**: `write_batch` is no longer
    atomic with respect to concurrent readers — a reader racing a batch can observe some of its
    writes but not others. This is safe for Linera's actual usage: only one writer ever exists
    per chain at a time (block execution is sequential per chain), so writes never race each
    other, only overlap with readers.
  - Verified: `cargo test -p linera-views --test store_tests --features test` — 10/10 relevant
    tests pass (1 pre-existing ignored). Full workspace check across
    `linera-storage-service`/`linera-service` is clean.
  - **Measured impact** (see section 4 for the numbers): ~9-11% lower `write_batch`/`contains_key`
    latency at a fixed 45k tx/s load, and a clean, isolated **+13.1% max-throughput ceiling**
    gain (41,512.5 → 46,965 tx/s at 19 shards, same core-pinning config as the old baseline —
    see section 3.2 for how the isolation was done).

Committed and pushed to `light_client` as commit `fbb2c4c3ab`. A fresh checkout of
`light_client` now includes this fix — no manual steps needed.

## 2. Scripts (all in `linera-paper-eval/scripts/`, branch `michal`)

All of these assume two real machines reachable over SSH — a validator host (`sparta` in the
SSH config used this session) and a client host (`yiannis-testbed`) — not the Docker Compose
flow described in the main `README.md`. See `README.md`'s new "Running across two real
machines" section for the manual step-by-step; the scripts below automate that.

| Script | Purpose | Key env vars | Output |
|---|---|---|---|
| `extract_binaries.sh` | Builds `linera`, `linera-server`, `linera-proxy`, `linera-storage-server`, `linera-lite-benchmark` locally into `./bin` | — | binaries |
| `run_node.sh` | Starts a full validator (storage-server + N shards + proxy, optionally the manager) on the validator host | `NUM_SHARDS`, `CORES_PER_SHARD` (0=unpinned), `RESERVED_CORES`, `STORAGE_CORES`, `SHARD_TOKIO_THREADS` (new — decouple shard thread count from pinned core count), `BASE_SHARDS`, `START_MANAGER`, `MANAGER_*` | running node, logs in `$STATE_DIR` |
| `stop_node.sh` | Clean SIGTERM-then-poll-then-SIGKILL teardown of everything `run_node.sh` started | `STATE_DIR` | — |
| `provision_super_owner_chains.sh` | Creates a pool of super-owner chains on the client host for benchmarking | `NUM_CHAINS` | `chain_pool.txt` |
| `run_lite_benchmark_parallel.sh` | Runs N parallel `linera-lite-benchmark` client processes against a chain pool | `NUM_CLIENTS`, `CHAINS_PER_CLIENT`, `BPS_PER_CLIENT` (or `BPS_SCHEDULE`), `TRANSACTIONS_PER_BLOCK`, `TRAFFIC_MODE` | per-client `transfers.csv` |
| **`find_max_tps.sh`** | Builds+deploys (or reuses, `SKIP_BUILD=true`), starts a node, provisions a chain pool sized for `MAX_CLIENTS × CHAINS_PER_CLIENT`, then **ramps client count** from `START_CLIENTS` to `MAX_CLIENTS` in `CLIENT_STEP` increments, `RUNTIME_SECONDS` per level, stopping when p95 latency exceeds 3× the first level's baseline. Reports the last good level as "max sustained throughput". | `NUM_SHARDS`, `CORES_PER_SHARD`, `RESERVED_CORES`, `CHAINS_PER_CLIENT`, `TRANSACTIONS_PER_BLOCK`, `TRAFFIC_MODE`, `BPS_PER_CLIENT`, `START_CLIENTS`, `CLIENT_STEP`, `MAX_CLIENTS`, `RUNTIME_SECONDS` | log with a per-level table + "Estimated max sustained throughput" line |
| **`run_shard_count_sweep.sh`** | Loops `find_max_tps.sh` over `MIN_SHARDS..MAX_SHARDS`, one shard count at a time, collecting each into one `summary.csv`. Supports `SHARD_LIST="7 8 10"` to rerun specific counts instead of a contiguous range. | `MIN_SHARDS`, `MAX_SHARDS` (or `SHARD_LIST`), plus everything `find_max_tps.sh` takes | `summary.csv` (`num_shards,num_clients,...,achieved_tps,...`) |
| **`plot_tps_vs_shards.py`** | Plots `summary.csv` → max sustained TPS vs. worker count, with a linear-scaling reference line | `<summary_csv> [output_path]` | `tps_vs_shards.png`/`.pdf` — **the "does throughput scale with worker count" figure** |
| **`run_elasticity_experiment.sh`** | Starts a node with `START_MANAGER=true`, drives ONE continuous `run_lite_benchmark_parallel.sh` with an auto-built `--bps-schedule` (low→med→dip→peak→med→peak→med→tail), records clock-offset/start-epoch metadata for later log alignment | `BASE_SHARDS`, `NUM_SHARDS`, `LOW_BPS`, `PEAK_BPS`, `MED1_FRACTION`, `MED2_FRACTION`, `SEG_*` (segment durations), manager watermarks | combined `transfers.csv`, `manager.log`, `metadata.txt` |
| **`plot_elasticity.py`** | 3 stacked plots sharing an x-axis: requested/achieved BPS, latency (p25-p95 band), and active shard count (parsed straight from `manager.log`'s own `info!` lines) | `<experiment_dir> [output_path]` | `elasticity.png`/`.pdf` — **the "worker count adapts to load" figure (paper Fig. 6)** |
| **`profile_metrics.sh`** | Snapshots Prometheus `/metrics` from every shard+proxy before/after a fixed-duration load burst, diffs the counters/histograms — no perf, no root needed | `NUM_SHARDS`, `CORES_PER_SHARD`, `RESERVED_CORES`, `STORAGE_CORES`, `SHARD_TOKIO_THREADS`, `RUNTIME_SECONDS`, `NUM_CLIENTS`, `CHAINS_PER_CLIENT`, `BPS_PER_CLIENT`, `TRANSACTIONS_PER_BLOCK` | `report.txt` — Tokio utilization/park events, per-RPC-method latency, storage-op latency breakdown |
| `analyze_metrics_snapshot.py` | The diffing logic behind `profile_metrics.sh`; can be run standalone on two snapshot dirs | `<before_dir> <after_dir> <runtime_seconds>` | same `report.txt` format |
| `open_faucet_tunnel.sh` | SSH-tunnels the faucet port (the only other port besides the proxy's public port that ever needs client↔validator traffic) | `SSH_HOST`, `REMOTE_FAUCET_PORT` | tunnel |
| `chains_per_client_sweep.sh`, `find_max_single_chain_tps.sh`, `run_lite_benchmark_sweep.sh`, `run_lite_benchmark.sh`, `run_client.sh`, `deploy_and_smoke_test.sh` | Earlier/narrower variants and smoke tests, not the main line of investigation this session but still functional | see each script's own header | various |

**Note on `find_max_tps.sh`'s CPU-attribution columns** (`sparta_reserved_pct`,
`sparta_shard_pct` in its per-level table): these are computed as `/proc/stat` utilization over
a *fixed core range* (`0..RESERVED_CORES-1` for the proxy/storage, `RESERVED_CORES..
RESERVED_CORES+NUM_SHARDS*CORES_PER_SHARD-1` for shards). **This is meaningless whenever
`CORES_PER_SHARD=0`** (unpinned) — the shard range collapses to empty and always reports 0.0,
and the "reserved" range just samples whatever happens to land on cores 0..1 by scheduler
luck, not actually the proxy. Only trust these columns when `CORES_PER_SHARD>0`. For unpinned
runs, use a direct `ssh sparta "ps -eo pid,pcpu,comm --sort=-pcpu"` snapshot instead (see
section 3.2).

## 3. Lessons learned

### 3.1 Client count / chains-per-client / BPS tuning

- **Chain pool sizing must match the *planned max*, not the current step.** Early in the
  elasticity work, a chain pool was calibrated against a 290-chain pool but only 60 chains were
  actually provisioned for the real run — achieved throughput plateaued far below what the
  validator could actually do, because the client simply ran out of independent chains to drive
  concurrently. `find_max_tps.sh`/`run_shard_count_sweep.sh` provision `MAX_CLIENTS ×
  CHAINS_PER_CLIENT` chains up front for exactly this reason — don't shrink that pool between
  runs without re-provisioning.
- **Integer division silently zeroes low-but-nonzero rates.** Any time a per-client or
  per-chain rate is computed by dividing an aggregate (`total_bps / num_clients /
  num_chains_per_client`), doing that division in integer arithmetic can round a genuinely
  positive rate down to exactly 0 — not sparse traffic, *permanently zero* traffic until the
  aggregate rate rises enough to round back up to 1. This bit both the Rust client
  (`lite_benchmark.rs`) and the bash pre-division in `run_lite_benchmark_parallel.sh`. Always
  divide in floating point (or round up, not down, in bash) when the numbers could plausibly be
  small.
- **A coarse ramp step size produces misleading "identical" or "plateaued" results.** With
  `CLIENT_STEP=4`, two adjacent shard counts can report byte-for-byte identical "max sustained"
  throughput purely because the ramp's discrete grid happened to sample the same last-good
  level for both — not because they have equal true capacity. The actual degradation point is
  noisy (single-sample-per-run), and a coarse grid quantizes that noise into apparent plateaus.
  Finer `CLIENT_STEP` (2 instead of 4) and/or multiple repeats per level would give a cleaner
  signal; the sweeps run this session did not average repeats.
- **A gradual ramp and a fixed-load snapshot test the same config very differently.**
  `find_max_tps.sh` ramps client count up gradually; `profile_metrics.sh` jumps straight to the
  target client count from a cold start. On the exact same node configuration (skiplist storage,
  shards pinned to 2 cores each), the gradual ramp found a healthy 46,965 tx/s sustained
  ceiling, while the fixed-jump snapshot at a comparable client count achieved barely half that,
  with 5-10x worse per-operation latency. **This is unresolved** — see section 5. Don't directly
  compare a `profile_metrics.sh` number against a `find_max_tps.sh` ceiling number without
  accounting for this; they're not measuring the same thing.

### 3.2 Pinning workers / storage / proxy

- **The original default (`RESERVED_CORES=2`, i.e. proxy+storage share a fixed 2-core budget)
  creates a hard throughput ceiling around ~20,000 tx/s, completely independent of shard
  count.** Confirmed directly: `sparta_reserved_pct` (the proxy+storage core range) hit ~80%
  utilization right as every ramp's stop condition tripped, while `sparta_shard_pct` (the
  shards' own cores) sat at only ~19-20%. Shards 7 through 19 in that config were essentially
  idle, waiting on a saturated 2-core proxy+storage budget — adding more shards past ~6 did
  nothing.
- **Unpinning the proxy and storage-server (`RESERVED_CORES=0`, letting them float across any
  core) roughly doubled peak throughput** (from ~20,000 to ~43,500-50,000 tx/s depending on
  shard count), because it removed that artificial ceiling. This is the config the final
  shard-count-sweep figure (`results/tps_vs_shards/20260805_115053_unpinned/`) uses.
- **`taskset` pinning does not reserve cores exclusively from *other*, unpinned processes.**
  It only restricts what cores the *pinned* process itself can use. So pinning shards to a
  fixed core range while leaving the proxy/storage-server unpinned does **not** protect those
  shard cores from being invaded by the proxy — the unpinned proxy is still free to land on the
  exact same cores a shard is confined to. This is one plausible (not fully confirmed —
  see section 5) explanation for why pinned-shard configs are much more sensitive to sudden load
  bursts than fully-unpinned ones.
- **`--tokio-threads` is currently hardcoded to equal `CORES_PER_SHARD`** in `run_node.sh`.
  Decoupling them (new `SHARD_TOKIO_THREADS` env var, added this session) and testing 8 threads
  on 2 pinned cores did **not** fix the pinned-shard burst-sensitivity problem — throughput barely
  moved (+4.9%) and per-op latency got slightly *worse* (more threads contending for the same 2
  physical cores adds context-switch overhead). So it's not simple thread starvation either —
  see section 5 for what's still unexplained.
- **Direct process-level CPU inspection (`ps -eo pid,pcpu,comm --sort=-pcpu` on the validator
  host) is more trustworthy than the script's own CPU-attribution columns** whenever anything
  is unpinned (see the table note in section 2). It's what revealed `linera-proxy` running at
  ~201% CPU — busier than any individual shard, and not scaling with shard count at all, since
  there's only ever one proxy process.

## 4. Results summary

**Hardware**: validator host `sparta` — 40 logical cores (2× Intel Xeon E5-2640 v4 @ 2.40GHz,
10 cores/socket, 2 threads/core), 188GB RAM. Client host `yiannis-testbed` — 16 cores, 62GB RAM.
Both UCL-managed machines reached over SSH (aliases `sparta`/`yiannis-testbed`); occasional
transient DNS/connection blips observed (self-resolving, just retry).

**Max TPS vs. worker count** (`results/tps_vs_shards/`):
- Pinned proxy/storage (`RESERVED_CORES=2`, old default): hard ceiling ~20,000 tx/s for any
  shard count ≥7 — proxy/storage-bound, not shard-bound (see 3.2).
- Unpinned proxy/storage: roughly linear scaling 1→6 shards (3,587 → 18,962 tx/s), then noisy
  but still-climbing growth through 19 shards, peaking at **43,561 tx/s at 15 shards**, 41,512
  tx/s at 19 shards. Final figure: `results/tps_vs_shards/20260805_115053_unpinned/tps_vs_shards.png`.

**Storage optimization** (`profile_out/`, `results/max_tps_skiplist/`):
- `parking_lot` swap: reverted, 3-4x worse latency under real ~45k tx/s contention.
- `crossbeam-skiplist` rewrite: kept. Isolated (same core-pinning as the old baseline, only the
  storage backend changed) throughput ceiling: **41,512.5 → 46,965 tx/s, +13.1%**. ~9-11% lower
  `write_batch`/`contains_key` latency at a fixed 45k tx/s load.

**Elasticity / auto-scaling** (`results/elasticity/`, final run `20260804_223135/`):
Real, working end-to-end: a continuous time-varying `--bps-schedule` drives changing load
against a node with `linera-server manager` running; the manager scales workers up under
sustained high load and back down when it drops, all visible in `manager.log` and the final
3-panel figure (`elasticity.png`) — requested/achieved throughput, latency, and active shard
count over time, all correctly aligned on one x-axis. Two real bugs were found and fixed getting
here (integer-division-to-zero traffic, and a plot x-axis end-time bug that made the shard-count
panel appear to jump backward at the end) — see git history / section 3.1.

**Storage profiling deep-dive**: the low "aggregate Tokio utilization" number (~4.7% throughout)
is *not* a useful signal on its own — it's dominated by the size of a mostly-idle 800-thread
pool, not by per-operation efficiency. The real, verified signal for whether a storage change
helped is the ceiling test (section 4, above), which is unambiguous.

## 5. Open questions / suggested next steps

1. **The proxy bottleneck is real but not fully explained.** Direct measurement shows
   `linera-proxy` running ~201% CPU, unpinned, busier than any individual shard, and it
   structurally can't scale with shard count (there's only ever one). The likely mechanism is
   double protobuf serialization + double network hop (decode incoming → re-encode outgoing →
   decode shard's response → re-encode back to caller, for every single request) — but this
   wasn't confirmed with actual per-stage profiling, only reasoned about. OpenTelemetry export
   overhead was checked and ruled out (no collector endpoint configured, code falls back to
   plain tracing). A proper next step would be a bounded profiling pass isolating decode vs.
   route-lookup vs. re-encode vs. network cost inside the proxy specifically.
2. **The pinned-shard burst-sensitivity finding is unresolved.** A gradual ramp and a
   fixed-load-jump on the *identical* config gave wildly different results (46,965 tx/s
   sustained vs. roughly half that under a cold-start burst). Neither "proxy CPU contention"
   nor "shard thread starvation" (tested directly, didn't help) fully explains it. A controlled,
   apples-to-apples ramped comparison of pinned vs. unpinned shards (same starting conditions,
   same warm-up) would help nail this down before trusting either number in isolation.
3. Sweep results in this session are **single-sample per configuration** — no repeats, no error
   bars. If these numbers are going in the paper, consider re-running key configurations 2-3x to
   get a sense of run-to-run variance (the noisy sawtooth in the unpinned shard-count sweep
   suggests it's non-trivial).

## 6. Practical notes

- Cleanup if a run leaves stray processes on the validator host:
  `ssh sparta "pkill -9 -f 'linera-server|linera-proxy|linera-storage-server'"`. `stop_node.sh`
  does this cleanly in the normal case; only needed after an interrupted/crashed run.
- Long experiments (a full 19-shard sweep, an elasticity run) take from ~10 minutes to
  ~2-3 hours; run them backgrounded (`nohup ... &`) and check on them periodically rather than
  blocking a terminal.
- `results/` and `profile_out/` hold every run's raw logs/CSVs/reports from this session,
  timestamped by directory name — useful for re-deriving any number in this note.
