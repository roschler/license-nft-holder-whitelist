#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${AENEID_RPC_URL:-https://aeneid.storyrpc.io/}"

# We pin the block number to make the addresses and 
#  return data deterministic.
#
# export FORK_BLOCK_NUMBER to pin; grab once via `cast block-number --rpc-url $RPC_URL`
BLOCK="${FORK_BLOCK_NUMBER:-}"

args=(--fork-url "$RPC_URL" -vvv)
if [ -n "$BLOCK" ]; then
  args+=(--fork-block-number "$BLOCK")
fi

forge clean
forge build
forge test "${args[@]}" | tee test-report.txt
