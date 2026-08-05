# Linera Paper Eval

Evaluation code for Linera.

## Building

The build process is automated in Docker.
It builds both a recent linera validator/storage server/... and the evaluation binaries.

You will need

- A Linux machine
- Docker
- A storage engine for docker that supports caching (e.g. the `containerd` storage driver)
- A lot of disk space for the Linera build, probably on the order of 100GB

Then, build using

```bash
./build_docker_paper_eval_binaries.sh
```

Alternatively, you can also build manually.

## Running

The experiments are set up in a way to put databases, wallets, etc. into a directory at `/ramdisk`,
and output data into a directory at `/data_out`.
By default, these are mounted as volumes at `/media/ramdisk` and `./data_out` on the host.
The experiments are controlled via environment variables, see `run_docker_paper_eval.sh`.

After building, run the experiments in Docker using

```bash
./run_docker_paper_eval.sh
```

this will run the experiments.
Each experiment starts a Linera network in a specific configuration and executes the benchmark against it.
Results will be stored in `data_out/`, owned by a user with UID 1000.

## Running across two real machines (bare metal, no Docker)

`linera net up` (used above) hardcodes every validator address to `localhost`, so it only
works when the validator and the client run in the same container. To get a real, remotely
reachable single validator (e.g. for a throughput ceiling test with the client on a separate
machine), use the plain-process scripts instead:

```bash
./scripts/extract_binaries.sh          # builds and extracts linera, linera-server,
                                        # linera-proxy, linera-storage-server, linera-paper-eval
                                        # into ./bin, no Docker needed at runtime
```

Copy `linera`, `linera-server`, `linera-proxy`, `linera-storage-server` to the testbed and
`linera`, `linera-paper-eval` to the client machine.

Only two ports ever need to leave the testbed: the proxy's **public port**, which carries all
benchmark traffic (so it should be the one port your firewall opens directly — no tunnel on
the hot path), and the **faucet**, which is only hit once at startup to claim chains and is
low-stakes enough to go through an SSH tunnel instead. Shards, the storage-service, and the
proxy's internal/metrics ports never leave the testbed at all.

```bash
# On the testbed (validator machine), reachable at e.g. 10.0.0.5, with 4001 the one
# port your firewall opens directly (SSH on 22 is assumed available separately):
NODE_HOST=10.0.0.5 PROXY_PUBLIC_PORT=4001 ./scripts/run_node.sh
# prints the faucet's local port and the tunnel command to use

# On the client machine, tunnel the faucet over SSH (leave this running):
SSH_HOST=10.0.0.5 REMOTE_FAUCET_PORT=8080 ./scripts/open_faucet_tunnel.sh &

# ...then run the client against the tunneled faucet and the direct proxy port:
FAUCET_URL=http://127.0.0.1:8080 ./scripts/run_client.sh
```

`run_node.sh` starts a `linera-storage-server` in `memory` mode (RAM-backed, shared by all
shards), the shard(s), the proxy (public port pinned to `PROXY_PUBLIC_PORT`, reachable at
`NODE_HOST`), and a faucet bound only locally. `NUM_SHARDS`, `STORAGE_PORT`, `FAUCET_PORT`,
`STATE_DIR` etc. are overridable via env vars (see the top of the script). Stop everything
with `scripts/stop_node.sh`.

If your testbed instead has no separate SSH access and only one directly-reachable port
total, both the proxy and the faucet would need to sit behind an L7 reverse proxy (e.g.
nginx/Envoy) demultiplexing gRPC vs. HTTP on that single port — a heavier setup than the
scripts here currently support.

## Throughput sweeps with the light client (primary path for Section VII.C)

`linera-paper-eval` drives every transaction through a full `ChainClient`: local storage,
local WASM execution, full signature handling. That client-side overhead can itself become
the bottleneck before the validator does. For the Section VII.C throughput sweep, prefer
[`linera-lite-benchmark`](https://github.com/harnen/linera-protocol/tree/light_client), a
storage-free client that only signs bare block proposals and trusts validator responses —
built from the fork pinned in `Dockerfile.linera-paper-eval-builder-base`
(`LINERA_GIT_URL`/`LINERA_GIT_REV`), already included by `extract_binaries.sh`.

It only works on chains owned by a single **super owner** (so every block can use the
one-round-trip `Round::Fast` path), which also means chain setup never needs a faucet: the
node's `admin_wallet.json` (already produced by `run_node.sh`) owns the genesis chain outright
and can fund children directly via `linera open-chain --super-owner`.

```bash
# Copy the node's admin wallet and genesis config to the client (only the proxy's public
# port is ever touched). The genesis config is needed so provision_super_owner_chains.sh
# can seed this client's own local storage with the admin chain's ChainDescription --
# without it, `linera open-chain` fails with "Blobs not found: ChainDescription".
scp node:$STATE_DIR/admin_{wallet,keystore}.json node:$STATE_DIR/genesis.json ./

# Provision, e.g., 20 super-owner chains from it:
LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  NUM_CHAINS=20 ./scripts/provision_super_owner_chains.sh

# Run a single point (independent/mixed/full traffic, tunable bps and tx/block):
LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  BPS=1000 TRANSACTIONS_PER_BLOCK=10 TRAFFIC_MODE=full RUNTIME_SECONDS=60 \
  ./scripts/run_lite_benchmark.sh

# ...or sweep num_chains x traffic_mode x tx_per_block x bps in one go:
LINERA_WALLET=./admin_wallet.json LINERA_KEYSTORE=./admin_keystore.json \
  ./scripts/run_lite_benchmark_sweep.sh
```

Each run writes `transfers.csv` (`chain_id,ts_within_experiment,num_tx,result,duration_micros`
— the same schema `linera-paper-eval` uses) plus a log with the live "N blocks/s committed"
line, under `$EVAL_OUTPUT_DIR/lite_benchmark/<experiment_name>/`.

`run_client.sh`/`linera-paper-eval` remain available as the full-fidelity fallback (the one
that still models real `ChainClient` overhead), useful for comparing against the lite client's
numbers.

## Profiling CPU usage without `perf`/root

On a shared/restricted testbed where `perf` is blocked (`perf_event_paranoid` too high, no
sudo) and `bpftrace`/`gdb`/`py-spy` aren't usable either, the validator's own built-in
Prometheus metrics (`linera-metrics` crate) are enough to see where time goes -- no code
changes, no extra tools. They just need building with `--features metrics` (already added to
`find_max_tps.sh`/`deploy_and_smoke_test.sh`), since it's not a default Cargo feature.

```sh
# Starts a fresh validator, snapshots every shard's + the proxy's /metrics before and after
# a load-generating run, and diffs the counters/histograms into a report (rebuild with
# --features metrics first if reusing older binaries):
./scripts/profile_metrics.sh
# tune the load: NUM_CLIENTS, CHAINS_PER_CLIENT, BPS_PER_CLIENT, RUNTIME_SECONDS
```

The report separates real latency histograms (ms, "where does time go") from size/byte
histograms (data volume, not time -- easy to conflate since Prometheus uses the same
`*_sum`/`*_count` suffix convention for both), and cross-checks RPC-level latency and
per-operation latency against the Tokio runtime's own busy-time counters (real on-CPU time
per worker thread) to tell apart genuine compute cost from waiting/contention. Output goes to
`./profile_out/<timestamp>/` (raw snapshots + `report.txt`).

## TODO

- We need to untangle the evaluation client from the node and the Docker setup.
  This should be pretty easy, just build the eval client binary, extract it, point it at the RAMdisk and the fountain,
  and stuff should work. It'll need a few non-hardcoded parameters, but it should be doable.
  Alternatively, we could also provide the admin wallet (which contains the genesis config) instead of the fountain.
- We can probably get rid of the chain balancing, and maybe even the balance checking, once we're sure that
  things work correctly.
  This will save us a lot of time on the benchmarks.
- Something about the inbox processing or something is flaky.
    This shows when querying balances sometimes. Something about different order of things.
- Instead of passing around `(ChainDescription, AccountOwner)`, we should probably pass around `ChainClient`s and maybe `ChainId`s.
- We create the chains from the fountain, which works, but is a bit slow and weird.
    The `linera benchmark` implementation does this much nicer, and I think we can do the same.
    For that to work we need to use the admin wallet, and then a bunch of methods on the `ClientContext` or something.
    I found that the only combination of wallets and keystores that are created that works is
    `keystore_1.json`, `wallet_1.json`, and `client_0.db`. No clue why.
- The startup script probably does some useless stuff, like creating the second wallet.
    Then again, that wallet and keystore work with `linera benchmark`, whereas the first wallet and keystore don't.
- The variable load experiments currently operate in three phases:
    1. 30 seconds of `k` chains at `target_bps` blocks per chain with `num_tx` in each block.
    2. 30 seconds of `k` additional chains at `target_bps` blocks per chain with `num_tx` in each block.
    3. 30 seconds without the additional chains, i.e., back to the first phase.
    
    This works, but is not that flexible. Maybe we want something else than double the load at some point.
    The implementation is flexible enough, we just need to specify it, and name the output directories in a way that makes sense.
- The entire data I/O situation of the tool is pretty bad at the moment.
    We should create a few structs that represent the data we need to store, instead of passing around tuples etc.
- The `linera benchmar` implementation is much nicer, we could copy that and add something to export the features we need,
    but I found that it sometimes behaves weirdly under load, so I'd like to keep the current implementation.
- The `linera benchmark` implementation uses a `ChainListener`.
    I don't know if we need that, I don't know if we're somehow already using it under the hood, no clue.
- We could make the client lighter, maybe. This will make things faster, probably.
- I have no idea if we should close the chains at the end of the benchmark (doesn't matter, the network is killed anyway),
    or maybe even in between experiments, and use fresh chains.
    At some point the chains will become quite long, which is probably bad.
    I ran into trouble because the fountain runs dry at some point, we could fix this with the method `linera benchmark`
    uses to create chains, because they can give them a custom (smaller) starting balance,
    which seems to be impossible via the fountain (?).
- It is possible to run a Linera validator against ScyllaDB on RAMdisk if we enable `--developer-mode 1`.
    The performance of this is unclear, to be tested, but close to a real deployment, I guess.
