<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.png">
    <img src="assets/banner-light.png" alt="Mercurifi Agent Accounts — Your agent trades. Only you withdraw." width="100%">
  </picture>
</p>

<p align="center">
  <img src="assets/mark.svg" width="56" height="56" alt="">
</p>

<h1 align="center">Mercurifi Agent Accounts · contracts</h1>

<p align="center">
  <a href="deployments/5042.json"><img src="https://img.shields.io/badge/Arc_mainnet-chain_5042-C3E6FF?style=flat-square" alt="Arc mainnet, chain 5042"></a>
  <a href="deployments/5042002.json"><img src="https://img.shields.io/badge/Arc_testnet-chain_5042002-C3E6FF?style=flat-square" alt="Arc testnet, chain 5042002"></a>
  <a href="deployments/5042.json"><img src="https://img.shields.io/badge/release-1.0.0--beta.1-0A0A0A?style=flat-square" alt="release 1.0.0-beta.1"></a>
  <a href="#build-and-verify"><img src="https://img.shields.io/badge/build-pinned-0A0A0A?style=flat-square" alt="build pinned"></a>
  <a href="foundry.toml"><img src="https://img.shields.io/badge/solidity-0.8.26-0A0A0A?style=flat-square" alt="Solidity 0.8.26"></a>
  <a href="src/AgentAccount.sol"><img src="https://img.shields.io/badge/accounts-EIP--1167_clones-0A0A0A?style=flat-square" alt="EIP-1167 clones"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-0A0A0A?style=flat-square" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://launch.mercuri.finance">launch.mercuri.finance</a> ·
  <a href="https://trade.mercuri.finance">trade.mercuri.finance</a> ·
  <a href="https://docs.mercuri.finance">docs.mercuri.finance</a> ·
  <a href="https://github.com/mercuri-finance/mercurifi-sdk">SDK (TypeScript, Python)</a>
</p>

The Solidity source of Mercurifi Agent Accounts: per-user vaults on Arc from which the owner's own bot or AI agent
trades within caps the owner sets. Agent keys can buy and sell on Mercurifi Launch bonding curves, swap on graduated
Launch pools through Uniswap's Universal Router, launch tokens and claim creator fees. They can never withdraw. Only the
owner can withdraw, and only to itself. Contracts, the pinned sources they compile against, the deployment inputs and
the release evidence. The backend, the [SDK](https://github.com/mercuri-finance/mercurifi-sdk) and the web app are separate.

The accounts span Launch (curves, launches, fees) and the graduated pools, so they live in their own repository, apart
from the Launch and Trade contract sets. Launch's deployed contracts stay in
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts) and are never changed for them.

**Contents** · [Deployment](#deployment) · [How it works](#how-it-works) · [Contracts](#contracts) ·
[Parameters](#parameters) · [Events](#events) · [Differences from Launch](#differences-from-launch) ·
[Build and verify](#build-and-verify) · [Security](#security) · [License](#license)

## Deployment

Version 1.0.0-beta.1, on Arc mainnet and Arc testnet, both deployed on 10 October 2026 from the same contract source
(testnet from commit `e1210d5`, mainnet from `b882653`, whose `src/` is identical). **No third-party audit has been
performed yet**: mainnet went live on the owner's decision after the testnet run and the reviews described under
[Security](#security). Start with small amounts.

| Contract | Address (mainnet, chain 5042) | Mutability |
| --- | --- | --- |
| AgentAccountFactory | [`0x816C7269FDcf621b7d8cb99A5AfbE9daddBd3b58`](https://explorer.arc.io/address/0x816C7269FDcf621b7d8cb99A5AfbE9daddBd3b58) | immutable |
| AgentPolicyRegistry | [`0x318A0e1353E812A36FC7C52a88Af8D6A96909483`](https://explorer.arc.io/address/0x318A0e1353E812A36FC7C52a88Af8D6A96909483) | immutable |
| AgentAccount (implementation) | [`0x36acC3Eb67571E592A45c88656c4B3c4f7Fb7beE`](https://explorer.arc.io/address/0x36acC3Eb67571E592A45c88656c4B3c4f7Fb7beE) | immutable |

| Contract | Address (testnet, chain 5042002) | Mutability |
| --- | --- | --- |
| AgentAccountFactory | [`0x6D56A15c25782FF638943A4E81A1eD1ea862C9Bd`](https://explorer.testnet.arc.io/address/0x6D56A15c25782FF638943A4E81A1eD1ea862C9Bd) | immutable |
| AgentPolicyRegistry | [`0xcfCDA6a022314eA7Ae995cCf88e4eeB3A8802C69`](https://explorer.testnet.arc.io/address/0xcfCDA6a022314eA7Ae995cCf88e4eeB3A8802C69) | immutable |
| AgentAccount (implementation) | [`0xD11567fDfc9833E39E7EEbB0964c7bB7f4FF40b5`](https://explorer.testnet.arc.io/address/0xD11567fDfc9833E39E7EEbB0964c7bB7f4FF40b5) | immutable |

Full records: [`deployments/5042.json`](deployments/5042.json) (mainnet) and
[`deployments/5042002.json`](deployments/5042002.json) (testnet). On both networks the runtime bytecode of all three
matches this repository's build (`script/verify-agent-accounts.py`), and the source is published on Sourcify.

The inputs are in [`deployments/manifest-5042002.json`](deployments/manifest-5042002.json) (testnet) and
[`deployments/manifest-5042.json`](deployments/manifest-5042.json) (mainnet). Every Launch address in them must equal
Launch's deployment record for the chain, `admin` its timelock and `guardian` its guardian; the Universal Router and its
runtime hash are pinned and reproduced from the upstream source. The deployment script predicts the implementation,
factory and registry addresses from the deployer's nonce and refuses to finish unless all three land there, wired as
the manifest says.

| Dependency | Address (testnet, chain 5042002) | Mutability |
| --- | --- | --- |
| LaunchFactory | [`0x08D8CDDA59b5ce9216F7eD9B34E1F0391C80cC0E`](https://explorer.testnet.arc.io/address/0x08D8CDDA59b5ce9216F7eD9B34E1F0391C80cC0E) | proxy · Mercurifi Launch |
| FeeManager | [`0xcE1260DF73dEEbD71A869CC4E9A2006994f3E5E2`](https://explorer.testnet.arc.io/address/0xcE1260DF73dEEbD71A869CC4E9A2006994f3E5E2) | proxy · Mercurifi Launch |
| GraduationManager | [`0x3A17cD90e34EBae71D92013f763FD01bAef1efdc`](https://explorer.testnet.arc.io/address/0x3A17cD90e34EBae71D92013f763FD01bAef1efdc) | proxy · Mercurifi Launch |
| LaunchHook | [`0x87e6BaBAc4598F99f4A0717ad294934455Fe60cc`](https://explorer.testnet.arc.io/address/0x87e6BaBAc4598F99f4A0717ad294934455Fe60cc) | immutable · Mercurifi Launch |
| Universal Router | [`0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1`](https://explorer.testnet.arc.io/address/0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1) | immutable · upstream |
| Permit2 | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://explorer.testnet.arc.io/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) | immutable · upstream |
| Uniswap v4 PoolManager | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://explorer.testnet.arc.io/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) | immutable · upstream |
| USDC | [`0x3600000000000000000000000000000000000000`](https://explorer.testnet.arc.io/address/0x3600000000000000000000000000000000000000) | Arc system contract · upstream |
| Admin | [`0x41129B5215cA24b29a4cABcaE26d3569744DEe2E`](https://explorer.testnet.arc.io/address/0x41129B5215cA24b29a4cABcaE26d3569744DEe2E) | Launch's TimelockController |

On mainnet the admin is Launch's mainnet timelock (48-hour delay) and the guardian is the Guardian Safe; the mainnet
manifest lists the Launch addresses of Launch's mainnet record,
[`deployments/5042.json`](https://github.com/mercuri-finance/mercuri-launch-contracts/blob/main/deployments/5042.json).

## How it works

1. **Create.** `createAccount` on the factory clones the account implementation (EIP-1167, CREATE2 with the owner in
   the salt), registers the owner, the policy and an optional first agent in the registry, and binds an optional
   referrer at Launch's FeeManager for the account's lifetime.
2. **Fund and configure.** The owner sends USDC (Arc's native gas token) to the account and manages it in the
   registry. Narrowing a policy or revoking an agent takes effect at once; every widening (a new agent, a higher cap,
   an allowlisted token, a shorter delay, a new owner) waits the account's delay in a queue the owner can cancel.
3. **Trade.** An agent key calls the account's typed functions: `buy` and `sell` on a curve, `swapExactIn` on the
   token's graduated pool, `launch`, `claimFees`, `sweepToOwner`. The account builds every external call itself from
   Launch's contracts, never from an address the agent names, and the registry checks the agent, its permission and
   deadline, the pauses and the period caps before the trade, then charges the measured spend after it.
4. **Withdraw.** Only the owner can withdraw, only to itself: `withdraw` for one asset, `withdrawMany` for many. A
   pause stops agent functions only; the owner's exits always work.

What a stolen agent key can lose per period, the trust model, migration and gas are set out in
[`docs/agent-accounts.md`](docs/agent-accounts.md).

## Contracts

| File | Role | Mutability |
| --- | --- | --- |
| [`AgentAccount.sol`](src/AgentAccount.sol) | The account implementation behind every clone. Holds the funds, the per-token cost basis and the bound referrer; runs the typed agent trades and the owner's withdrawals. No generic execute, delegatecall, upgrade or selfdestruct; `isValidSignature` always fails. | immutable, testnet |
| [`AgentPolicyRegistry.sol`](src/AgentPolicyRegistry.sol) | One per factory, deployed by its constructor. Every account's owner, policy, agents, allowlist, delay, widening queue, owner pause and period usage; authorizes each agent call and charges each trade to the caps. No admin and no owner of its own. | immutable, testnet |
| [`AgentAccountFactory.sol`](src/AgentAccountFactory.sol) | Creates and records accounts, holds the beta policy ceilings and the guardian pause of agent functions. Holds no funds. | immutable, testnet |

Shared types and policy maths: [`libraries/AgentTypes.sol`](src/libraries/AgentTypes.sol),
[`libraries/AgentPolicyLib.sol`](src/libraries/AgentPolicyLib.sol). Interfaces in [`src/interfaces/`](src/interfaces).

Pinned sources it builds against (details in [`lib-versions.md`](lib-versions.md)):

| Path | What it is | Status |
| --- | --- | --- |
| `lib/mercuri-launch-contracts` | Launch's deployed sources and records, and the Uniswap v4, Permit2 and OpenZeppelin upgradeable trees Launch pins | Git submodule, pinned |
| `lib/openzeppelin-contracts`, `lib/forge-std` | The OpenZeppelin v5.4.0 and forge-std trees Launch vendors | Git submodules, pinned |
| `lib/universal-router`, `lib/uniswap-v2-core`, `lib/uniswap-v3-core` | Uniswap/universal-router `999d561` (2.1.1), the revision behind Arc's router, and the two npm versions it pins | Git submodules, pinned; the 110-file closure is checksummed and built separately with `script/build-universal-router.sh` |
| `test/` | Behaviour, attack, fuzz, gas, invariant, deploy-script and pinned-fork tests, with the Launch and Uniswap v4 fixtures they need | Local |

## Parameters

Beta ceilings, fixed in the factory's bytecode: no account policy may exceed them, and lifting them is a new factory.
An account's own policy, set by its owner, sits at or below them.

| Parameter | Ceiling |
| --- | --- |
| Per action (`maxTradeUsdc`) | 1,000 USDC |
| Spend per period, all tokens (`periodSpendCap`) | 10,000 USDC |
| Spend per period, one token (`perTokenPeriodCap`) | 2,000 USDC |
| Sells per period, valued at cost (`periodSellCap`) | 10,000 USDC |
| Agent actions per period (`maxActionsPerPeriod`) | 5,000 |
| Launches per period (`launchesPerPeriod`) | 20 |
| Price impact of the account's own trade (`maxPriceImpactBps`) | 20% |
| Curve snipe tax a buy accepts (`maxSnipeBps`) | 99% |
| Agent deadline (`maxDeadlineSeconds`) | 600 seconds |

Fixed for every account: at most 8 agents, each expiring within 180 days; a period of 1 hour to 7 days, chosen at
creation; a widening delay of at most 7 days; queued items expire 7 days after they become executable. The guardian
can pause agent functions for 72 hours, then must wait 72 hours; the admin can lift or shorten a pause, or extend an
active one to at most 30 days from now. Amounts are in USDC with 6 decimals (`usdc6`); native balances use 18.

## Events

For indexers and the SDK. Every registry event carries the account as its first indexed parameter.

```solidity
// AgentAccountFactory
event AccountCreated(address indexed owner, address indexed account, address indexed referrer, bytes32 salt);
event AgentsPausedUntil(uint40 until, address by);
event GuardianSet(address guardian);

// AgentAccount — action: 1 buy, 2 sell, 3 launch, 4 pool buy, 5 pool sell, 6 claim, 7 sweep
event AgentAction(address indexed agent, uint8 action, address indexed token, uint256 usdcSpent, uint256 usdcReceived,
                  int256 tokenDelta, uint256 basisValue, uint64 periodId);
event AccountWithdrawn(address indexed token, uint256 amount);

// AgentPolicyRegistry
event PolicyApplied(address indexed account, Policy policy);
event PolicyQueued(address indexed account, uint256 indexed id, uint40 eta, Policy policy);
event AgentActivated(address indexed account, address indexed agent, uint40 expiresAt, uint16 permissions);
event AgentQueued(address indexed account, uint256 indexed id, address indexed agent, uint40 expiresAt,
                  uint16 permissions, uint40 eta);
event AgentRevoked(address indexed account, address indexed agent, uint40 expiresAt, uint16 permissions);
event TokenAllowed(address indexed account, address indexed token, bool allowed);
event TokenAllowQueued(address indexed account, uint256 indexed id, address indexed token, uint40 eta);
event IncreaseDelaySet(address indexed account, uint32 delay);
event IncreaseDelayQueued(address indexed account, uint256 indexed id, uint32 delay, uint40 eta);
event OwnershipQueued(address indexed account, uint256 indexed id, address indexed newOwner, uint40 eta);
event AccountOwnerChanged(address indexed account, address indexed previousOwner, address indexed newOwner);
event QueuedExecuted(address indexed account, uint256 indexed id);
event QueuedCancelled(address indexed account, uint256 indexed id);
event AgentsPaused(address indexed account, bool paused);
```

USDC amounts in `AgentAction` are `usdc6`, measured as the account's native balance delta (spent rounded up, received
rounded down); `tokenDelta` is in the token's 18-decimal units. Launch's own events (`Buy`, `Sell`, `HookFee`,
`FeeAccrued`, `TokenCreated`) fire as for any trader, with the account as trader or creator.

## Differences from Launch

This repository follows the deployed Launch contracts' layout, style and release tooling. Where it differs, on purpose:

| Launch | Here | Why |
| --- | --- | --- |
| Three UUPS proxies with ERC-7201 storage, `storage-layouts/` and upgrade tests | No proxy: the account implementation, registry and factory are immutable; nothing to upgrade, no storage layout to preserve | Nobody, the admin included, can change what an account does with its funds. A new version is a new implementation and factory, and owners migrate (docs, section 6). There is no code rollback. |
| `lib/` committed as plain files | Git submodules of the public upstream repositories, pinned by commit | Launch is itself a dependency here; submodules pin it and the upstream trees by commit without copying them. |
| Depends on Uniswap v4 only | Also calls the Universal Router (and Permit2) for pool swaps | The account swaps on the deployed router with calldata it builds itself; the router's runtime hash is pinned and reproduced from the upstream source, and the tests build that source. |
| `deployments/<chainId>.json` written by the deploy wrapper | `deployments/manifest-<chainId>.json` inputs; `deployments/<chainId>.json` written only by `script/write-agent-accounts-record.py` from a completed broadcast | The record must equal what was broadcast and match the reviewed manifest; the writer never overwrites one. As in Trade. |
| `check-natspec.py` checks functions | Also checks every custom error and event | Errors and events are what a reverted call or an indexer shows; as in Trade. |
| No static analysis in the gate | Slither 0.11.3 against a triaged baseline, when installed | Every result is triaged in [`docs/reports/`](docs/reports). |
| Version 1.0.0 | `VERSION` = `1.0.0-beta.1` | Beta ceilings apply until a new factory lifts them. |

## Build and verify

```sh
git clone --recurse-submodules https://github.com/mercuri-finance/mercuri-agent-contracts.git
cd mercuri-agent-contracts
# The pinned router, read by the tests from out/universal-router:
bash script/build-universal-router.sh
forge build
bash script/check-contracts.sh
```

`forge build` uses the pinned settings in [`foundry.toml`](foundry.toml): Solidity 0.8.26, Cancun, via-IR, per-path
optimizer runs (200 for `src/**`), no metadata hash. `bash script/build-universal-router.sh` checks the router's 110
sources against their keccak256 manifest and compiles them with the router's own settings, leaving this repository's
compiler profiles alone. [`lib-versions.md`](lib-versions.md) records every pin.

The gate checks the source manifest, formatting, NatSpec, the record writer's and the verifier's offline self-tests and
both manifests, then runs every test with seed `0x5042`, the gas snapshot and, when installed, Slither. For the stress
pass (a 10,000-run fuzz pass, the pinned fork tests and the deep invariant campaign of 1,024 runs at depth 256), point
it at Arc's public RPC or a loopback fork of it, never a paid provider. The fork cases that need Arc's USDC precompiles
run on Arc's own node through `eth_call`, so they skip on a loopback fork:

```sh
ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io AGENT_FORK_CHAIN_ID=5042002 bash script/check-contracts.sh --stress
```

[`script/verify-agent-accounts.py`](script/verify-agent-accounts.py) is read-only. `--preflight` checks a manifest
against Launch's record for the chain, the beta ceilings and the reproduced router; `--simulate` runs the constructors
of the built code with the manifest inputs as `eth_call`s and compares the result with the rebuilt runtimes; with
`--record` it compares the deployed implementation, factory and registry with the freshly compiled artifacts at one
block, every immutable reconstructed and every other byte required to match:

```sh
python3 script/verify-agent-accounts.py --simulate --rpc https://rpc.testnet.arc.io
forge script script/DeployAgentAccounts.s.sol --rpc-url https://rpc.testnet.arc.io   # dry run, no --broadcast
```

[`script/write-agent-accounts-record.py`](script/write-agent-accounts-record.py) writes `deployments/<chainId>.json` in
the shape of Launch's deployment records, only from a completed forge broadcast whose receipts, chain, commit and
constructor arguments match the manifest, and never overwrites a record.

## Security

| | |
| --- | --- |
| [`docs/agent-accounts.md`](docs/agent-accounts.md) | Architecture, trust model, the loss bound for a stolen agent key, what is immutable, pause powers, migration, gas and the release evidence. |
| Mutability | All three contracts are immutable: no proxy, upgrade or rescue path, and no admin over accounts or funds. |
| Governance | The factory's admin is Launch's timelock: it can replace the guardian and lift, shorten or extend an active pause, never start one or touch an account. The guardian can pause agent functions for 72 hours. What each can do: [`SECURITY.md`](SECURITY.md). |

The contract set was reviewed before the move to this repository, and the final review approved it for testnet; the
static analysis is triaged in [`docs/reports/`](docs/reports). The spec asked for an external audit before mainnet;
the owner chose to deploy mainnet before one, and an audit remains open.

These were AI-assisted reviews, not an audit by a security firm; no third-party audit has been performed yet. Weigh
that before relying on the contracts. To report a vulnerability, see [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) for the contracts in `src/`. Dependencies under `lib/` keep their own licenses.

---

<sub>Mercurifi and Mercurifi Agent Accounts are independent products. They are not affiliated with, sponsored by or
endorsed by Circle Internet Group, Inc. or its affiliates. Arc and USDC are trademarks of Circle Internet Group, Inc.
and/or its affiliates, named here only to say which network and which asset the contracts work with. Uniswap is a
trademark of Uniswap Labs.</sub>
