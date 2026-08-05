#!/usr/bin/env bash
set -euo pipefail

# Extracts the release binaries (linera, linera-server, linera-proxy,
# linera-storage-server, linera-paper-eval) as plain files, so they can be
# copied (e.g. via scp) onto bare-metal machines and run without Docker.
#
# Output: ./bin/{linera,linera-server,linera-proxy,linera-storage-server,linera-paper-eval}

BUILD_PROFILE="${BUILD_PROFILE:-release}"

case "${BUILD_PROFILE}" in
  release)
    CARGO_PROFILE_FLAG="--release"
    TARGET_DIR="release"
    ;;
  debug)
    CARGO_PROFILE_FLAG=""
    TARGET_DIR="debug"
    ;;
  *)
    echo "Unsupported BUILD_PROFILE: ${BUILD_PROFILE}" >&2
    echo "Expected 'release' or 'debug'." >&2
    exit 1
    ;;
esac

rm -rf ./bin
mkdir -p ./bin

echo "==> Building linera-protocol binaries (linera, linera-server, linera-proxy, linera-storage-server)"
docker buildx build \
  -f Dockerfile.linera-paper-eval-builder-base \
  --build-arg TARGET_DIR="$TARGET_DIR" \
  --build-arg CARGO_PROFILE_FLAG="$CARGO_PROFILE_FLAG" \
  -t linera-paper-eval-builder-base --load .

docker create --name linera-paper-eval-extract-base linera-paper-eval-builder-base
docker cp linera-paper-eval-extract-base:/out/. ./bin/
docker rm linera-paper-eval-extract-base

echo "==> Building linera-paper-eval binary"
docker buildx build \
  -f Dockerfile.linera-paper-eval \
  --target builder \
  --build-arg TARGET_DIR="$TARGET_DIR" \
  --build-arg CARGO_PROFILE_FLAG="$CARGO_PROFILE_FLAG" \
  -t linera-paper-eval-builder --load .

docker create --name linera-paper-eval-extract-eval linera-paper-eval-builder
docker cp linera-paper-eval-extract-eval:/out/. ./bin/
docker rm linera-paper-eval-extract-eval

chmod +x ./bin/*
echo "==> Done. Binaries are in ./bin:"
ls -la ./bin
echo "==> Copy the validator binaries (linera, linera-server, linera-proxy, linera-storage-server) to the testbed,"
echo "    and the client binaries (linera, linera-paper-eval) to the client machine, e.g.:"
echo "      scp ./bin/{linera,linera-server,linera-proxy,linera-storage-server} user@testbed:~/bin/"
echo "      scp ./bin/{linera,linera-paper-eval} user@client:~/bin/"
