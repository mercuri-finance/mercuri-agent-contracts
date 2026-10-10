#!/usr/bin/env bash
# Agent accounts candidate checks. Local only: no .env loading, signing or broadcasting.
#
#   bash script/check-contracts.sh            # the gate
#   ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io AGENT_FORK_CHAIN_ID=5042002 bash script/check-contracts.sh --stress
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--stress") ]]; then
  echo 'usage: bash script/check-contracts.sh [--stress]' >&2
  exit 2
fi

# Tests write their exports (the invariant statistics, the loopback address book) to the ignored test-export/.
mkdir -p test-export
# The deployed sources must be exactly the reviewed ones.
python3 script/check-local-source.py
# Every check below reads out/. Start from an empty one so no artifact the current configuration no longer builds can
# satisfy a check.
forge clean
# The pinned upstream Universal Router (its closure is checked against its keccak manifest before it compiles).
bash script/build-universal-router.sh
forge fmt --check
forge build
python3 script/check-natspec.py
# The agent accounts record: only from a completed DeployAgentAccounts broadcast, never overwritten.
python3 script/write-agent-accounts-record.py --self-test
# Both manifests must agree with Launch's records, the reproduced Universal Router and the spec 4.5 beta ceilings, and
# a copy of the mainnet manifest with one ceiling raised must be refused.
python3 script/verify-agent-accounts.py --preflight
python3 script/verify-agent-accounts.py --preflight --manifest deployments/agent-accounts-manifest-5042.json
pending_dir=$(mktemp -d)
trap 'rm -rf "$pending_dir"' EXIT
python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); m["ceilings"]["maxTradeUsdc"] += 1; json.dump(m, open(sys.argv[2], "w"))' \
  deployments/agent-accounts-manifest-5042.json "$pending_dir/agent-accounts-manifest-5042.json"
if raised=$(python3 script/verify-agent-accounts.py --preflight --manifest "$pending_dir/agent-accounts-manifest-5042.json" 2>&1); then
  echo 'verify-agent-accounts.py --preflight accepted a manifest with a ceiling above spec 4.5' >&2
  exit 1
fi
grep -q 'ceilings.maxTradeUsdc .* != spec 4.5 beta ceiling' <<<"$raised" || { echo "raised-ceiling preflight failed without its report: $raised" >&2; exit 1; }
# A copy of the testnet manifest naming the mainnet router runtime hash must be refused against the reproduced router.
python3 -c 'import json, sys; m = json.load(open(sys.argv[1])); m["routerCodeHash"] = json.load(open(sys.argv[2]))["routerCodeHash"]; json.dump(m, open(sys.argv[3], "w"))' \
  deployments/agent-accounts-manifest-5042002.json deployments/agent-accounts-manifest-5042.json \
  "$pending_dir/agent-accounts-manifest-5042002.json"
if swapped=$(python3 script/verify-agent-accounts.py --preflight --manifest "$pending_dir/agent-accounts-manifest-5042002.json" 2>&1); then
  echo 'verify-agent-accounts.py --preflight accepted a manifest with the other network'"'"'s router hash' >&2
  exit 1
fi
grep -q 'routerCodeHash .* does not match the reproduced router' <<<"$swapped" || { echo "router-hash preflight failed without its report: $swapped" >&2; exit 1; }
# Runtime identity: the verifier must accept the rebuilt implementation, factory and registry runtimes with every
# immutable substituted and reject a flipped byte in each immutable by name (the full sweep runs in --self-test; the
# pairs below are re-run here so the gate itself sees each contract's mismatch report).
python3 script/verify-agent-accounts.py --self-test
for pair in 'account:FACTORY' 'account:REGISTRY' 'account:LAUNCH_FACTORY' 'account:UNIVERSAL_ROUTER' \
  'factory:implementation' 'factory:registry' 'factory:admin' 'factory:guardianDisabled' 'factory:C_MAX_TRADE_USDC' \
  'registry:FACTORY'; do
  if flipped=$(python3 script/verify-agent-accounts.py --self-test-flipped "$pair" 2>&1); then
    echo "verify-agent-accounts.py accepted a runtime with a flipped ${pair#*:} byte (${pair%%:*})" >&2
    exit 1
  fi
  grep -q "MISMATCH at offsets.*inside immutables: ${pair#*:})" <<<"$flipped" || { echo "${pair} self-test failed without its mismatch report: $flipped" >&2; exit 1; }
done
forge test --fuzz-seed 0x5042
# Agent account gas: deterministic agent tests only.
forge snapshot --check --no-match-contract 'Fork|Invariant' --no-match-test '^testFuzz_' --fuzz-seed 0x5042
# Slither over the agent contracts: offline, about 15 s, on a temporary copy of the tree. It runs when Slither 0.11.3
# is installed (or SLITHER names it) and then every result must match the triaged baseline; otherwise a notice only,
# since Slither is a Python tool outside the repo. The release evidence always records a full run of the script.
slither_bin=${SLITHER:-slither}
if command -v "$slither_bin" > /dev/null && [[ $("$slither_bin" --version 2> /dev/null) == 0.11.3 ]]; then
  SLITHER="$slither_bin" bash script/run-slither.sh
else
  echo "notice: Slither 0.11.3 not installed (set SLITHER to it); skipping the agent Slither baseline check"
fi

if [[ ${1:-} == "--stress" ]]; then
  : "${ARC_LOCAL_FORK_RPC:?set ARC_LOCAL_FORK_RPC to the public Arc RPC or a loopback fork of it}"
  : "${AGENT_FORK_CHAIN_ID:?set AGENT_FORK_CHAIN_ID to 5042 or 5042002}"
  # Every invariant suite runs in the deep campaign below, so the 10,000-run fuzz step leaves it out.
  FOUNDRY_FUZZ_RUNS=10000 forge test --no-match-contract 'AgentInvariantsTest' --fuzz-seed 0x5042
  # Agent account invariants (spec section 5), 1,024 runs at depth 256, their own counterexample directory.
  agent_campaign_dir=$(mktemp -d -t mercuri-agent-invariant)
  echo "Agent invariant counterexamples, if any: $agent_campaign_dir"
  FOUNDRY_INVARIANT_RUNS=1024 FOUNDRY_INVARIANT_DEPTH=256 \
    FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
    FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR="$agent_campaign_dir" \
    forge test --match-path 'test/invariant/AgentInvariants.t.sol' --match-contract 'AgentInvariantsTest' \
    --fuzz-seed 0x5042002
fi
