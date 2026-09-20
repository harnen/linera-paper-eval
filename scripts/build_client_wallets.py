#!/usr/bin/env python3
"""Build minimal per-client wallet.json/keystore.json files in one pass.

run_lite_benchmark_parallel.sh used to `cp` the *entire* admin wallet/keystore into every
client's directory (linera-persistent takes an exclusive flock on open, even for reads, so
clients can't share one file). That's fine at small chain-pool sizes, but once the pool grows
into the tens/hundreds of thousands of chains (e.g. via provision_super_owner_chains_parallel.sh)
the admin wallet itself becomes tens of MB, and copying it per client blows through the
Grid5000 NFS home quota within a few thousand clients -- confirmed the hard way: a 31.5MB
wallet.json (100,050 chains) times ~1000 clients/host was ~5-6GB/host and exhausted quota at
the 5000-client level, silently corrupting that level's result (some clients' `cp` failed
mid-write, so they never started, while committed/failed counts looked deceptively clean).

Each client only ever touches its own CHAINS_PER_CLIENT chains, so it only needs a wallet
containing those chains' entries (plus genesis_config) and a keystore containing just their
owners' keys -- a few KB regardless of how big the shared pool is. Building all of them in one
Python process (load the admin wallet/keystore once, slice, write) is also far faster than
either N full copies or N separate `jq` invocations re-parsing the whole pool file each time.
"""
import argparse
import json
import os


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--wallet", required=True)
    p.add_argument("--keystore", required=True)
    p.add_argument("--chain-ids-file", required=True)
    p.add_argument("--client-index-offset", type=int, default=0)
    p.add_argument("--num-clients", type=int, required=True)
    p.add_argument("--chains-per-client", type=int, default=5)
    p.add_argument("--outdir", required=True)
    args = p.parse_args()

    with open(args.wallet) as f:
        wallet = json.load(f)
    with open(args.keystore) as f:
        keystore = json.load(f)

    with open(args.chain_ids_file) as f:
        chain_ids = [line.strip() for line in f if line.strip()]

    owner_to_key = {k[0]: k for k in keystore["keys"]}
    genesis_config = wallet["genesis_config"]
    prng_seed = keystore.get("prng_seed")

    for i in range(args.client_index_offset + 1, args.client_index_offset + args.num_clients + 1):
        start = (i - 1) * args.chains_per_client
        end = i * args.chains_per_client
        client_chain_ids = chain_ids[start:end]

        client_chains = {cid: wallet["chains"][cid] for cid in client_chain_ids}
        owners = {c["owner"] for c in client_chains.values()}
        client_keys = [owner_to_key[o] for o in owners if o in owner_to_key]

        client_dir = os.path.join(args.outdir, f"client_{i}")
        os.makedirs(client_dir, exist_ok=True)

        client_wallet = {
            "default": client_chain_ids[0] if client_chain_ids else wallet["default"],
            "chains": client_chains,
            "genesis_config": genesis_config,
        }
        with open(os.path.join(client_dir, "wallet.json"), "w") as f:
            json.dump(client_wallet, f)

        client_keystore = {"keys": client_keys, "prng_seed": prng_seed}
        with open(os.path.join(client_dir, "keystore.json"), "w") as f:
            json.dump(client_keystore, f)


if __name__ == "__main__":
    main()
