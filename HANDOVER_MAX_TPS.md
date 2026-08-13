# Handover: measuring max TPS with the light client

**Goal.** Find the maximum throughput of a properly deployed validator (ScyllaDB, real
hardware), driven by `linera-lite-benchmark` from another region so the numbers include real
WAN latency. Runs are short (~60 s per load level).

Our own numbers came from a LAN with an in-memory backend, so they're not the ones we want here.
The load generator, the chain provisioning, and the search methodology transfer directly.
This note covers what to reuse, the one patch you'll need, and what to record.

---

## 1. Driving the light client

The client needs `admin_wallet.json`, `admin_keystore.json` and `genesis.json` from the
validator, plus a pool of super-owner chains. Two scripts do the work:

```bash
# Provision the chain pool (no faucet; batches OpenChain ops ~900 per block)
LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
NUM_CHAINS=$((MAX_CLIENTS * CHAINS_PER_CLIENT)) OUTPUT_FILE=./chain_pool.txt \
  ./scripts/provision_super_owner_chains.sh

# One load level: N parallel client processes, each on a disjoint slice of the pool
LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
CHAIN_IDS_FILE=./chain_pool.txt NUM_CLIENTS=32 CHAINS_PER_CLIENT=20 \
BPS_PER_CLIENT=100 TRANSACTIONS_PER_BLOCK=10 TRAFFIC_MODE=independent \
RUNTIME_SECONDS=60 EVAL_OUTPUT_DIR=./results EXPERIMENT_NAME=level_32 \
  ./scripts/run_lite_benchmark_parallel.sh
```

**Every client process needs its own wallet/keystore copy.** `linera-persistent` takes a
non-blocking exclusive `flock` on open, even for reads, so N processes on one wallet means N-1
immediate "Resource temporarily unavailable" failures. `run_lite_benchmark_parallel.sh` already
copies per process.

### Sizing: chains per client is the setting to get right

Each chain proposes strictly sequentially — `run_chain` awaits `propose_and_commit` before its
next tick (`lite_benchmark.rs:582`), and each block carries `previous_block_hash`. So **one block
per chain is in flight at a time, and per-chain block rate is capped at 1/RTT** regardless of
what you ask for. This is the number that changes when you move the client to another region:
at 100 ms RTT a chain tops out near 10 blocks/s, at 200 ms near 5.

TODO: Leo thinks we need more than 1 RTT per block, but not sure.

Since a client spreads `BPS_PER_CLIENT` evenly over its chains, you want

```
CHAINS_PER_CLIENT  >=  2 x BPS_PER_CLIENT x RTT_seconds
```

(the 2 is headroom, so chains aren't pinned at their ceiling). At `BPS_PER_CLIENT=100` that's
20 chains at 100 ms RTT, 40 at 200 ms.
It might be worth to measure the RTT first and tune this.
Too few chains looks exactly like validator saturation, but is the client being latency-bound.

For 500k TPS at the Ethereum mean of ~163 tx/block you need ~3,075 blocks/s, i.e. ~31 clients at
`BPS_PER_CLIENT=100` — so the current per-client target rate is fine as-is, and the ramp simply
needs to reach ~31. Size the chain pool for the ramp ceiling
(`MAX_CLIENTS x CHAINS_PER_CLIENT`), not for the expected answer. One client step is then
~16k TPS of resolution; halve `BPS_PER_CLIENT` (and double the clients) if you want finer.

### Traffic modes and cross-chain messages

`independent` (self-transfers) / `mixed` (half self, half cross-chain) / `full` (always
cross-chain). In every mode except `independent`, each block **first drains the incoming message
bundles waiting in its chain's inboxes**, then appends its own operations — so a block's work is
`num_tx` operations plus `num_bundles` received bundles, and both are recorded per block.

- We'd suggest leaving `--max-incoming-bundles-per-block` unset. It defaults to twice that
  block's own operation count, which self-tunes with variable block sizes.
- We'd also suggest leaving `--single-destination-per-block` off (the default), so transfers
  spread across destinations rather than all landing in one recipient's inbox per block.
  Feels like cheating otherwise :)
- **Destinations are drawn only from the chains that same process drives.**
  `run_lite_benchmark_parallel.sh` gives each process a disjoint slice and passes no
  `--destination-chains`, so cross-chain traffic never leaves a client's own
  `CHAINS_PER_CLIENT` chains. That makes `CHAINS_PER_CLIENT` the cross-chain fan-out group size
  as well as the concurrency knob. Pass `--destination-chains` to let messages span the whole
  pool (those chains receive but never originate traffic, so they cost no sending capacity 
  on that client, but there'll be another client to handle the inboxes etc.

## 2. Scripts worth reusing

- `scripts/provision_super_owner_chains.sh` — as-is.
- `scripts/run_lite_benchmark_parallel.sh` — as-is plus the patch in §3. This is the load generator.
- `scripts/find_max_tps.sh` — **methodology reference, not a drop-in.** Stages [1/5]–[3/5]
  build binaries and start our own validator; you want only [4/5] provisioning and [5/5] the ramp.
  We use p95 latency to find the maximum throughput. Alternatively, you can also set it up to
  consider the ceiling when blocks start failing to commit.

Two things from the ramp are worth lifting:

**Coarse-to-fine client ramp** (`CLIENT_STEP_SCHEDULE`, e.g. `"25 5 1"`): walk the client count
up by a coarse step until a level fails, then re-walk the bracket at finer steps. A single fixed
step quantizes every result onto the `START_CLIENTS + k*step` grid — our first sweep returned
max-clients of exactly 6, 11, 16, 21, 26, 31, all ≡1 mod 5, which is an artifact of the search
rather than a property of the system. Coarse-to-fine is also cheaper: ~8–14 levels instead of
~100 for the same 1-client resolution. The floor is one client step, since total load is
`NUM_CLIENTS × BPS_PER_CLIENT`; lower `BPS_PER_CLIENT` for a finer grid.

**Re-test a failing level before accepting it** (`CONFIRM_STOP_RETRIES`, set to 2 in our runs).
Refinement only searches *below* the first failure, so one spurious failure caps that
configuration well below its true limit — a systematic downward bias that doesn't average out
over repetitions. Likelier over a WAN than it was on our LAN, so maybe increase.

## 3. Ethereum block-size distribution

`ethereum_txs_per_block_19m_to_21m.csv` holds per-block transaction counts for Ethereum blocks
19M–21M: **1,994,280 rows plus a `txs` header**. Mean 162.6, median 153, p90 237, p99 371,
max 1410, min 1.

`linera-lite-benchmark` supports this natively — no code changes:

```
--transactions-per-block-file <PATH>   # one size per line; overrides --transactions-per-block
--transactions-per-block-scale <F>     # 0.5 halves every block, 2.0 doubles it. We'll probably
                                       # just leave it as-is.
```

Each chain starts at its own random offset into the sequence and walks it one entry per block,
wrapping forever, so chains don't propose identically-sized blocks in lockstep
(`linera-service/src/lite_benchmark.rs:116-134`, offset picked at `:346`).

**Strip the header.** The parser skips blank and `#` lines but not text, so `txs` fails with
`invalid block size "txs" on line 1`:

```bash
tail -n +2 ethereum_txs_per_block_19m_to_21m.csv > eth_block_sizes.txt
```

**Patch needed:** `run_lite_benchmark_parallel.sh:110` only passes `--transactions-per-block`.
Add:

```bash
tx_args=(--transactions-per-block "${TRANSACTIONS_PER_BLOCK}")
if [ -n "${TRANSACTIONS_PER_BLOCK_FILE:-}" ]; then
  tx_args=(--transactions-per-block-file "${TRANSACTIONS_PER_BLOCK_FILE}"
           --transactions-per-block-scale "${TRANSACTIONS_PER_BLOCK_SCALE:-1.0}")
fi
```

and replace `--transactions-per-block "${TRANSACTIONS_PER_BLOCK}"` with `"${tx_args[@]}"`. The
file must be readable by every client process; they each read it at startup.

Note the mean of ~163 tx/block is ~16× our `TRANSACTIONS_PER_BLOCK=10` runs — size the chain
pool and `--bps` accordingly, maybe.

## 4. Data to collect

**The `transfers.csv` files are the primary record and are close to sufficient.** Schema
(`--output-csv`): `chain_id, ts_within_experiment, num_tx, num_bundles, result, duration_micros`,
one row per committed **or failed** block, where `num_tx` is the block's operation count and
`num_bundles` the incoming message bundles it drained. That yields throughput, block rate,
failure rate, the full latency distribution, and per-chain skew. `duration_micros` is
client-observed end-to-end (proposal → quorum) — the right quantity for a cross-region claim —
and `ts_within_experiment` is relative to each client's own start, so there's no cross-machine
clock-sync issue.

Please also keep:

- **Every load level, not just the winning one.** The load-vs-latency curve is the evidence;
  the single max number isn't much use without it. `find_max_tps.sh`'s `SUMMARY_CSV_PATH` writes
  one row per probed level for this reason.
- **Per-level metadata**: clients, chains/client, requested bps, tx/block setting (or block-size
  file + scale), traffic mode, runtime, binary commit SHA. Cheap now, unreconstructible later.
- **Client-side CPU/network**, enough to show the load generator wasn't the limit.

**Please repeat the whole experiment ~10 times.** A ramp is monotonic by construction, so
there's nothing to randomize within a run; the repetitions are what give the error bars, and
running them as 10 independent ramps (rather than 10 back-to-back measurements at each level)
puts time between repeats of the same level, so drift in the deployment lands in the spread
rather than hiding inside one level's samples.

Tidy long-format CSV — one row per observation, tagged with its repetition — is ideal. No need
to aggregate or plot; we'll do the evaluation on our end.

---

The scripts have dense header comments explaining the reasoning behind each knob. Happy to
answer questions.
