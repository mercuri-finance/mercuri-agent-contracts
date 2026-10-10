# Mercurifi Agent Accounts · contracts

Per-user agent accounts for Mercurifi on Arc: a vault from which the owner's own bot or AI agent trades within caps the
owner sets. Agent keys can buy and sell on Mercurifi Launch bonding curves, swap on graduated and listed Uniswap v4
pools through the canonical Universal Router, launch tokens and claim creator fees. They can never withdraw. Only the
owner can withdraw, and only to itself.

**Status: candidate, not deployed** on either network. The contracts span Mercurifi Launch (curves, launches, fees) and
pool swaps, so they live in their own repository, apart from the Launch and Trade contract sets.

| Contract | Kind |
| --- | --- |
| [`AgentAccount`](src/AgentAccount.sol) | Immutable implementation behind EIP-1167 clones, one clone per account |
| [`AgentPolicyRegistry`](src/AgentPolicyRegistry.sol) | Immutable singleton per factory: owners, policies, agents, delayed widening queue, period usage |
| [`AgentAccountFactory`](src/AgentAccountFactory.sol) | Immutable factory: CREATE2 clones, beta ceilings, guardian pause |

No proxy, no upgrade path, no admin over accounts or funds. The design, trust model, loss bound, immutability table,
pause powers, migration, gas and release evidence are in [`docs/agent-accounts.md`](docs/agent-accounts.md).

## Layout

| Path | Contents |
| --- | --- |
| `src/` | The three deployed contracts, `AgentPolicyLib`, `AgentTypes` and the interfaces; sha256 pinned in `source-manifest.json` |
| `test/` | Behaviour, attack, fuzz, invariant, gas, deploy-script and pinned-fork tests; `test/utils/` holds the Launch and Uniswap v4 fixture |
| `script/` | `DeployAgentAccounts.s.sol` (never run with `--broadcast` without an owner go), the record writer, the runtime verifier, the gate, Slither, the Universal Router build, and `local/` (loopback Anvil deployment for SDK tests) |
| `deployments/` | Per-network inputs (`manifest-<chainId>.json`); no deployment record exists yet |
| `docs/` | Contract documentation and reports |
| `lib/` | Git submodules (below) |

## Dependencies

All dependencies are Git submodules of public repositories, pinned by commit:

| Path | Repository | Pin |
| --- | --- | --- |
| `lib/mercuri-launch-contracts` | mercuri-finance/mercuri-launch-contracts | `99d7c28`; the deployed Launch sources, their deployment records, and the Uniswap v4, Permit2 and OpenZeppelin upgradeable trees Launch pins |
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts | v5.4.0 (`c64a1ed`), the `contracts/` tree Launch vendors |
| `lib/forge-std` | foundry-rs/forge-std | `5e38549`, the `src/` tree Launch vendors |
| `lib/universal-router` | Uniswap/universal-router | `999d561` (2.1.1), the revision of the router deployed on Arc |
| `lib/uniswap-v2-core` | Uniswap/v2-core | v1.0.1, the npm version the router pins |
| `lib/uniswap-v3-core` | Uniswap/v3-core | v1.0.0, the npm version the router pins |

The Universal Router is only built for tests and the loopback deployment: `script/build-universal-router.sh` assembles
its 110-file compiler closure from the submodules, checks every file's keccak256 against
`script/universal-router/source-manifest.json` and builds it with its own settings into `out/universal-router/`.

## Build and check

```sh
git clone --recurse-submodules https://github.com/mercuri-finance/mercuri-agent-contracts.git
cd mercuri-agent-contracts
bash script/check-contracts.sh
```

Foundry 1.4.3, Solidity 0.8.26, Cancun, via-IR, 200 optimizer runs for `src/**`, no metadata hash. The gate runs the
source manifest, the router build, `forge fmt --check`, `forge build`, the NatSpec check, the record writer and
verifier self-tests, the manifest preflights, every test with seed `0x5042`, the gas snapshot, and Slither 0.11.3 when
installed. `--stress` adds a 10,000-run fuzz pass, the pinned fork test and the deep invariant campaign
(1,024 runs at depth 256):

```sh
ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io AGENT_FORK_CHAIN_ID=5042002 bash script/check-contracts.sh --stress
```

Use Arc's public RPC or a loopback fork of it for fork tests, never a paid provider.

Read-only checks against a network:

```sh
python3 script/verify-agent-accounts.py --simulate --rpc https://rpc.testnet.arc.io
forge script script/DeployAgentAccounts.s.sol --rpc-url https://rpc.testnet.arc.io   # dry run, no --broadcast
```

## Security

Report vulnerabilities privately through GitHub's security advisory form for this repository. Do not open a public
issue for a vulnerability.

## Licence

[MIT](LICENSE).
