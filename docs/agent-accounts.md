# Mercurifi Agent Accounts: contracts

Status: **deployed on Arc testnet** (1.0.0-beta.1, [`deployments/5042002.json`](../deployments/5042002.json)); not deployed on mainnet. Authoritative design: the agent accounts spec of 9 October 2026
(sections 4, 5, 10 to 12). This page covers what the contracts in [`src/`](../src) do, what they trust,
what a stolen agent key can lose, what can never change, how users migrate, gas, and the release evidence.

## 1. Architecture

An agent account is a per-user vault from which the user's own bot or AI agent trades Launch tokens within caps the
owner sets. Agent keys can trade; they can never withdraw. The owner can withdraw (only to itself) and manage the
account; the owner has no trade path through the account.

| Contract | Kind | Runtime size | Holds | Role |
| --- | --- | --- | --- | --- |
| `AgentAccount` | Immutable implementation behind EIP-1167 clones (one clone per account) | 15,387 B | Native USDC, Launch tokens, per-token cost basis, the bound referrer | Typed agent trades (`buy`, `sell`, `swapExactIn`, `launch`, `claimFees`, `sweepToOwner`) and owner withdrawals. Builds every external call itself. No generic execute, no delegatecall, no proxy upgrade, no selfdestruct; `isValidSignature` always returns `0xffffffff`; `receive()` is empty. |
| `AgentPolicyRegistry` | Immutable singleton, one per factory, deployed by the factory's constructor | 17,838 B | Every account's owner, policy, agents, widening queue, allowlist, delay, owner pause and period usage | Owner functions (`addAgent`, `setPolicy`, `pauseAgents`, `transferOwnership`, ...), the agent preamble `authorize` and the cap accounting `record`. Only a registered account may call `authorize` or `record`, and only for itself. Emits every configuration event with `account` indexed. No admin, no owner of its own. |
| `AgentAccountFactory` | Immutable | 3,855 B | `isAccount`, the beta ceilings (immutables), the guardian and the pause deadline | `createAccount` (CREATE2 clone with salt `keccak256(abi.encode(owner, salt))`, registry `register`, account `initialize`), `predictAccount`, `ceilings`, the guardian pause. Holds no funds. |

`AgentPolicyLib` (internal library) and `AgentTypes` (structs and constants) are compiled into the contracts above.

Every Launch and Uniswap dependency (LaunchFactory, FeeManager, GraduationManager, LaunchHook, PoolManager, Universal
Router, Permit2, USDC) is a constructor immutable of the implementation, so every clone reads it from the
implementation's code. The implementation's constructor also takes the factory's address and the registry's (the
factory's first CREATE), predicted before either exists; the factory's constructor refuses an implementation that does
not name it and its registry.

Each agent action runs: account lock, registry `authorize` (owner pause, factory pause, active unexpired agent with the
permission, deadline in `[now, now + maxDeadlineSeconds]`, period roll, action count, and for `launch` only the launch
limit: `launches < launchesPerPeriod`, else `LaunchLimit`, before `maxTradeUsdc` and before any `LaunchFactory` call;
the launch is counted only after it succeeds), the account's own checks (genuine
curve from `LaunchFactory.curveOf`, or the GraduationManager's pool key through the LaunchHook, allowlist, snipe and age
limits, per-trade cap, price impact), the trade, the measured native-balance delta (spent rounded up to usdc6,
received rounded down), then registry `record` against the period caps.

## 2. Trust model

- **No admin over accounts.** Nobody but the account's owner can move its funds, and only to the owner. The factory's
  admin cannot touch accounts, policies or funds. There is no upgrade path for the account, the registry or the factory.
- **The registry is immutable** and has no owner; it trusts only its factory (for `register`) and registered accounts
  (for their own `authorize` and `record`).
- **Owner phishing** is slowed, not stopped: every widening (adding an agent, raising a cap, adding an allowlist token,
  lowering the delay, transferring ownership) waits `increaseDelay` (default 1 h, at most 7 days) in a queue that the
  owner can cancel, that a pause cancels, and that expires 7 days after its ETA. Narrowing is immediate.
- **Trusted upgradeable Launch components.** The account trusts Launch's `LaunchFactory.curveOf` registry, FeeManager
  and GraduationManager, which are UUPS proxies behind Launch's TimelockController (48 h delay on mainnet, 60 s on
  testnet). A malicious upgrade there could make an account treat a fake curve or pool as genuine (threat T12). This is
  the same trust every Launch trader already has, and it is the reason the account derives every curve and pool key
  from those contracts at execution time rather than accepting addresses from the agent.
- **Universal Router and Permit2** are used only with account-built calldata, exact transient approvals that must be
  zero after the call, and a post-trade balance check.
- **Tokens received from outside** (airdrops, transfers in, tokens beyond the recorded amount) have no cost basis and
  are valued by their pre-trade curve quote, or by the measured proceeds on a pool. An attacker can move that value, so
  holdings received from outside are not protected by the sell cap and should be withdrawn.

## 3. Loss bound, stated honestly

For a stolen agent key, per period (`periodSeconds`, fixed at creation, 1 h to 7 days):

- at most `periodSpendCap` of USDC spent on bad buys (curve buys, launch fees and initial buys, pool buys), and at
  most `perTokenPeriodCap` of it on any one token;
- plus holdings worth at most `periodSellCap` **valued at what the account paid** (the per-token average cost, or its
  high-water average if higher), sold badly;
- every single action is also capped at `maxTradeUsdc`.

Periods are fixed windows, so a key can spend **2x every period cap across a boundary** (the end of one period and the
start of the next). The total **keeps accruing period after period until the key is revoked, expires, or agents are
paused** by the owner or the guardian. Sell proceeds and fee claims never create headroom. With the spec defaults
(100 / 500 / 100 / 500 USDC, one-day period) a stolen key costs at most 500 USDC of bad buys plus 500 USDC of holdings
at cost per day, 1,000 + 1,000 across a day boundary. With the beta ceilings (1,000 / 10,000 / 2,000 / 10,000) the
corresponding bound is 10,000 + 10,000 per period, 20,000 + 20,000 across a boundary.

The price-impact limit measures the account's own trade from the already-moved price; it is not a sandwich defence.
Against a stolen key the caps are the control.

## 4. What is immutable

| Item | Where | Can change? |
| --- | --- | --- |
| Account, registry and factory code | all three | Never. No proxy, no upgrade, no code rollback. |
| Launch, Uniswap, Permit2 and USDC addresses | implementation immutables | Never (a new implementation and factory). |
| Beta ceilings (spec 4.5: 1,000 / 10,000 / 2,000 / 10,000 USDC; 5,000 actions; 20 launches; 2,000 bps impact; 9,900 bps snipe; 600 s deadline; `minTokenAgeBlocks` floor 0) | factory immutables | Never. Lifting them is a new factory (rollout phase 5). |
| Factory admin (the network's Launch timelock) | factory immutable | Never. |
| Guardian disabled (deployed with guardian zero) | factory immutable | Never; a factory with a guardian can never become guardian-less, and one without can never gain a pause. |
| An account's `periodSeconds` and FeeManager referrer | registry, FeeManager | Never for that account. |
| A retired (revoked) agent address | registry | Never re-addable to that account. |
| Constants: 8 agents, 180-day agent expiry, 7-day queue expiry, 7-day maximum delay, 600 s maximum deadline, 72 h guardian pause and cooldown, 30-day maximum admin extension | `AgentTypes.sol` | Never. |
| The guardian address | factory storage | Only the admin (timelock), never to zero. |
| An account's owner, policy, agents, allowlist and delay | registry storage | Only the owner: narrowing immediately, widening through the delayed queue. |

## 5. Guardian and admin pause powers

- The **guardian** (the Guardian Safe on mainnet, the Launch guardian key on testnet) can call `guardianPause()`: agent
  functions of every account of the factory stop for 72 hours. After a guardian pause ends the guardian must wait 72
  hours before pausing again, counted from the pause's original end even if the admin lifted it early.
- The **admin** (Launch's TimelockController) can lift or shorten any pause at any time, extend an *active* pause to at
  most 30 days from now, and replace the guardian (never with zero). It cannot start a pause.
- The 30 days run from each extension, not from the pause's start. While a pause is active the admin can extend it
  again before it ends, each time to at most 30 days from that moment, so a **rolling extension can keep agents
  paused indefinitely**. Each extension is its own timelock operation (48 h delay on mainnet), publicly queued, and
  owner exits keep working throughout.
- A pause **blocks agent functions only**. Owner withdrawals, `withdrawMany`, revocations, policy tightening and owner
  pause always work.
- A factory deployed with guardian zero has no pause at all, permanently: `guardianPause`, `setGuardian` and
  `adminSetPausedUntil` revert. The shipped manifests set a guardian on both networks (decision D2).

## 6. Migration

Accounts and factory are immutable, so a new version is a new implementation and a new factory (rollout phases 3 to 5).
Users migrate by:

1. pausing agents or revoking every agent key on the old account (immediate);
2. `withdrawMany(tokens)` on the old account, which sends native USDC (token `address(0)`) and every listed token to the
   owner. There is no on-chain token list, so a stolen key cannot make the exit run out of gas; the SDK and indexer
   supply the list. On Arc, chunk it: the SDK sends **100 tokens per transaction**; 200 is the largest proven fit
   (section 7);
3. `createAccount` on the new factory and depositing again.

The old factory keeps working; the web app marks it deprecated. There is no code rollback for any of the three
contracts.

## 7. Arc per-transaction gas cap

Arc enforces a per-transaction gas cap of **16,777,216** (2^24, EIP-7825 style) below the 30,000,000 block gas limit.
Verified read-only on 9 October 2026 against the public testnet RPC `https://rpc.testnet.arc.io` (client `arc/v1`,
chain 5042002, block 66,330,102, hash `0x2f1b9ed710dc92c88396668b8d5acf14b62db306ba27dc91ae2920f8b5363dd0`, gas limit
30,000,000): `eth_estimateGas` with a 50,331,648 gas allowance on a creation call that burns a fixed amount of gas
returned 16,577,103 for a 16.4M-gas loop and refused a 17.1M-gas and a 19.0M-gas loop with `-32003 out of gas: gas
required exceeds: 16777216`. The mainnet value has not been probed (no public mainnet RPC was reachable read-only);
treat it as the same until verified.

Consequences:

- `withdrawMany` of 500 cold tokens costs 18,200,591 gas and does **not** fit in one transaction; 200 tokens cost
  7,245,580 and fit with room to spare. `test_WithdrawManyAfter500DustBuysFitsInABlock` in
  [`AgentAttacks.t.sol`](../test/integration/AgentAttacks.t.sol) asserts a 200-entry `withdrawMany` runs under a
  16,777,216 gas limit after 500 dust buys by a stolen key. The SDK chunks at 100 tokens per transaction, half the
  proven 200-token fit.
- The deployment is two transactions (implementation, then factory with its registry); together they use about 7.6M
  gas, so each is well under the cap.

## 8. Gas

From the agent gas snapshot ([`.gas-snapshot`](../.gas-snapshot), checked by the gate) and the gas
logs of the agent tests, local fixture unless stated:

| Operation | Gas |
| --- | --- |
| Direct EOA curve buy (warm token), for comparison | 88,570 |
| Agent curve buy, same size | 131,103 (42,533 overhead) |
| Agent curve sell | 86,360 |
| Agent pool buy through the deployed testnet Universal Router and LaunchHook (fork, first action, cold; measured at `86cc00d`, seeds `0x5042` and `0x5042002`) | 420,219 |
| Agent pool sell, same pool (fork; measured at `86cc00d`, both seeds) | 235,046 |
| Agent launch with a 50 USDC initial buy through the deployed testnet Launch factory (fork at block 66,497,000; isolated call, cold) | 2,349,421 |
| Agent creator fee claim from the deployed testnet FeeManager (fork at block 66,497,000; isolated call, cold) | 79,161 |
| Agent curve buy that completes a testnet curve and graduates it (Arc node `eth_call` at block 66,497,000, account warm in the call) | 857,326 |
| Agent curve sell while `GraduationPending` (Arc node, same block, warm) | 85,716 |
| Agent pool buy / sell on the new pool with Arc's real USDC and Permit2 (Arc node, same block, warm) | 301,705 / 174,466 |
| `createAccount` with referrer binding and a first agent | 353,719 |
| Graduating agent buy, minimum call gas (cold) | 1,254,882 |
| `revokeAgent` | 45,879 |
| `withdrawMany` of 200 tokens / 501 tokens | 7,245,580 / 18,200,591 |
| Deploy implementation and factory (with registry), including the script's checks | 7,614,095 |

`createAccount` is above the spec's 200 to 250k planning figure: since the 9 Oct registry split it writes the full
policy, the first agent and the usage slots into the registry. At Arc gas prices this is a fraction of a cent.

## 9. Deployment

Inputs only, per network: [`deployments/manifest-5042002.json`](../deployments/manifest-5042002.json) and
[`deployments/manifest-5042.json`](../deployments/manifest-5042.json). Launch addresses come from Launch's deployment
record for the chain, the Universal Router and its runtime hash are the pins in
[`script/AgentDeployBase.sol`](../script/AgentDeployBase.sol) (reproduced by the preflight from the pinned upstream
router source and the bytes observed on chain,
[`docs/reports/2026-09-27-universal-router-comparison.json`](reports/2026-09-27-universal-router-comparison.json)),
`admin` is the network's Launch timelock, `guardian` is the record's guardian (the Guardian Safe on mainnet, the testnet
guardian key on testnet), and the ceilings are exactly spec 4.5. No deployed address is in them.

[`script/DeployAgentAccounts.s.sol`](../script/DeployAgentAccounts.s.sol) checks the manifest against those records
and the beta ceilings, requires code at every dependency and the pinned router runtime (and, on mainnet, a guardian
contract), predicts the implementation, factory and registry addresses from the deployer's nonce, deploys the
implementation and then the factory, and refuses to finish unless all three land where predicted and every immutable
and getter matches the manifest (`EXPECTED_AGENT_FACTORY` optionally pins the factory address). A deployment needs its
own owner go per network (decision D9); no task runs it with `--broadcast`.

After a broadcast, [`script/write-agent-accounts-record.py`](../script/write-agent-accounts-record.py) writes
`deployments/<chainId>.json` from forge's completed broadcast file, and only from that: no pending
transaction, exactly the implementation then the factory, both CREATEs from one sender at consecutive nonces with
status-1 receipts, the broadcast's chain and commit matching, the constructor arguments equal to the manifest (the
implementation naming the factory and the factory's first CREATE as registry), each input the built creation code with
those arguments, and the registry created by the factory at its predicted address from the built registry code; the
manifest must first pass the verifier's preflight. It refuses anything else and never overwrites a record: the record is
written to a temporary file and hard-linked into place, which fails if the name exists, so a record written by a
racing run is never replaced. Its `--self-test` (54 cases, in the gate) covers each refusal. No record exists: nothing
has been deployed.

Then `python3 script/verify-agent-accounts.py --rpc <Arc RPC> --block <n> --record deployments/<chainId>.json`
reads only that record (the writer's file name, key set and version, every input equal to the manifest), refuses a
block before the record's `factoryDeployBlock` (where every runtime is empty), rebuilds the
three runtimes from `out/` with the manifest and record values in every immutable and compares them byte for byte with
`eth_getCode`, checks the registry is the factory's first CREATE, the router's code hash and the factory's guardian;
`--account <addr>` also checks one clone.

## 10. Release evidence

Candidate: this repository after the repo-parity step. That step changed comments, NatSpec, import order and file
locations in `src/` (`AgentTypes.sol` and `AgentPolicyLib.sol` moved to `src/libraries/`), never code: runtime and
creation bytecode and the ABI of `AgentAccount`, `AgentAccountFactory` and `AgentPolicyRegistry` are byte-identical to
the build at `bddc7c9`, and so to the reviewed build (with `bytecode_hash = "none"` the only CBOR is the compiler
version). The evidence rows below are from the final run at `86cc00d` (10 Oct 2026), after the parity step; the move
itself was checked at the initial commit `f11162d` (gate exit 0, byte-identical bytecode, Universal Router pin
reproduced). The sources were moved from the Mercurifi Trade repository at `5f71ef5`, where the code candidate was
`6a559b3` and the independent final review approved it for testnet; rebuilding here at `f11162d` gave creation and
runtime code for `AgentAccount`, `AgentAccountFactory` and `AgentPolicyRegistry` byte-identical to the build at
`5f71ef5`. The move changed the deploy script and the verifier only where they read the Trade manifest: the Universal
Router address and runtime hash are now pinned in `script/AgentDeployBase.sol` and in the agent manifests, and the
preflight reproduces that hash from the pinned upstream router source. Baseline: Launch as pinned in
`lib/mercuri-launch-contracts` at `99d7c28` and its deployment records for 5042002 and 5042; the deployed Universal
Router `0x4fcA…9Fb1` at its pinned runtime hash. Toolchain: forge 1.4.3, solc 0.8.26, Cancun, via-IR, 200 optimizer runs
for `src/**`, no metadata hash. Missing evidence is pending, not pass. Final run: `bash script/check-contracts.sh
--stress` exit 0 in 23 min 51 s at `86cc00d` (public testnet RPC, Slither 0.11.3 in the gate).

| Requirement | Baseline | Candidate | Command or artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Source manifest | n/a | All eight `src/` sources listed with sha256; they differ from the reviewed sources only in comments, NatSpec, import order and location (repo-parity step) | `python3 script/check-local-source.py` (in gate) | Pass at `86cc00d`: 8 sources match | None |
| Bytecode identity after the move | Build in the Mercurifi Trade repository at `5f71ef5` | Build here at `f11162d` | `deployedBytecode` and `bytecode` of the three contracts compared, with and without the trailing CBOR | Byte-identical (runtime 15,387 / 3,855 / 17,838 B); immutable offsets identical | None |
| Bytecode identity after the parity step | Build at `bddc7c9` | Build after the repo-parity commits | `deployedBytecode`, `bytecode` and ABI of the three contracts compared (`cmp`) after each commit that touched `src/` | Byte-identical; ABI JSON identical | None |
| NatSpec | n/a | `AgentAccount`, `AgentAccountFactory`, `AgentPolicyRegistry` and their three interfaces | `python3 script/check-natspec.py` | Pass at `86cc00d`: 230 ABI entries, 0 failures | Semantic review of NatSpec is part of the independent review |
| Runtime identity | n/a | Every immutable of the implementation (10), factory (14) and registry (1) reconstructed; a flipped byte in each is rejected by name; extra or missing immutables refused; EIP-1167 clone check | `python3 script/verify-agent-accounts.py --self-test`, ten `--self-test-flipped` pairs (in gate) | Pass at `86cc00d`: MATCH 15,387 / 3,855 / 17,838 B; every flipped immutable (10 / 14 / 1) rejected by name; the gate's ten pairs reported | Live comparison against a real deployment is pending until a testnet deployment exists |
| Substitution correctness | n/a | Constructor simulations (`eth_call`, no transaction) of the built creation code with the testnet manifest inputs equal the reconstructed runtimes | `python3 script/verify-agent-accounts.py --simulate --block 66472381` against `https://rpc.testnet.arc.io` | MATCH at `86cc00d`, block 66,472,381: account 15,387 B, factory 3,855 B, registry 17,838 B | Mainnet simulation pending (no public mainnet RPC reachable) |
| Universal Router pin | n/a | `out/universal-router` rebuilt from the pinned submodules (110-file closure, every keccak checked) is byte-identical to the build the router comparison report matched on chain; with the report's immutables it reproduces the observed runtime (sha256) on both networks, whose keccak is each manifest's `routerCodeHash` with the manifest permit2 in every PERMIT2 slot | `bash script/build-universal-router.sh`; `verify-agent-accounts.py --preflight` (in gate) | Pass | None |
| Manifests | n/a | Inputs only (extra keys refused by the script and the preflight); Launch addresses = Launch records, admin = timelock, guardian = record guardian, router and hash = the pins and the reproduced router, ceilings = spec 4.5 | `verify-agent-accounts.py --preflight` for both; a raised-ceiling copy and a testnet copy with the mainnet router hash refused (in gate); `DeployAgentAccounts.t.sol` | Pass at `86cc00d`: both manifests clean; both tampered copies refused with their reports | Mainnet guardian code check runs only at deploy time (script requires code on 5042) |
| Deploy script | n/a | Predicts implementation, factory and registry from the deployer nonce; full wiring check; wrong chain and missing code refused; tampered manifests refused by field, including the other network's router hash | `test/local/DeployAgentAccounts.t.sol` (6 tests, in process against the fixture, never broadcast); the fork test runs `run()` against deployed testnet Launch; `forge script script/DeployAgentAccounts.s.sol --rpc-url https://rpc.testnet.arc.io` (no `--broadcast`, sender `0xf39F…2266`) | Pass at `86cc00d`: 6/6 local tests; dry run SIMULATION COMPLETE, every check passed, implementation `0x2a8A…Dd80`, factory `0x6806…d67B`, registry `0x527C…7312` predicted from that sender's nonce (9,221), about 10.7M gas estimated; no broadcast | Testnet deployment needs an owner go (D9) |
| Deployment record writer | n/a | `write-agent-accounts-record.py`: writes `<chainId>.json` only from a completed broadcast and only for a manifest that passes the preflight; links the record into place so an existing or racing record is never overwritten; names only HEAD of a clean tree as `sourceRevision`; the verifier's live mode reads only that record and refuses a block before `factoryDeployBlock` | `python3 script/write-agent-accounts-record.py --self-test` (in gate) and the verifier's record self-test | Pass at `86cc00d`: 54/54; record self-test passed | Run against the real broadcast at the testnet deployment |
| Behaviour, attack, fuzz, invariant tests | n/a | 213 agent tests | `bash script/check-contracts.sh` (seed `0x5042`) | Pass at `86cc00d`: 213 passed, 0 skipped (fork included, public RPC); snapshot check 194 passed | None |
| Stress | n/a | Gate with `--stress`: 10,000-run fuzz pass (fork suite included), then the agent invariants alone at 1,024 x 256 with their own counterexample directory | `ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io AGENT_FORK_CHAIN_ID=5042002 AGENT_INVARIANT_STATS=true bash script/check-contracts.sh --stress` | Pass at `86cc00d`: exit 0 in 23 min 51 s; 10,000-run fuzz 207 passed; agent invariants 6 passed at 1,024 x 256 (262,144 calls each, 0 reverts, no counterexample); depth-256 (6,150 runs) successful-step ratio 87.70% mean, 80.86% min, successful account-call ratio 82.82% mean, 76.88% min (floor 60%); 14,134 queue expiries, at least 1 every run | None |
| Pinned fork | n/a | `AgentPoolForkTest`: agent pool buy and sell (ERC-20 and Permit2 allowances back to zero; Alchemy URLs refused) through the deployed testnet Universal Router and LaunchHook on graduated token `0x97B4…eE84` at block 65,301,435, account deployed by the production script. `AgentLaunchForkTest`: spec 10's other fork cases against the deployed testnet agent factory and registry (`deployments/5042002.json`, never a fresh deployment) at block 66,497,000; see "Spec 10 fork cases" below | `ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io forge test --match-contract 'AgentPoolForkTest\|AgentLaunchForkTest'` (skipped without `ARC_LOCAL_FORK_RPC`; the Arc node cases also skip on a loopback Anvil fork) | Pass at `86cc00d` under seeds `0x5042` and `0x5042002`: pool buy 420,219 gas, sell 235,046. `AgentLaunchForkTest`: 6 passed against the public testnet RPC (gas in section 8) | A mainnet fork, once the accounts are deployed there |
| Gas | n/a | Snapshot `.gas-snapshot` (193 entries); identical to the reviewed snapshot except the four `DeployAgentAccountsTest` entries, whose test no longer reads a Trade manifest | `forge snapshot --check ...` (in gate) | Pass at `86cc00d` | None |
| Size | EIP-170 24,576 B | 15,387 / 3,855 / 17,838 B | `forge build --sizes` | Pass | None |
| Arc per-tx gas cap | Unverified (ruling: likely 16,777,216) | Verified on testnet (section 7) | `eth_estimateGas` probe, block 66,330,102 | 16,777,216 | Mainnet probe pending |
| Upgradeability and storage | n/a | No proxies; nothing to upgrade, no storage layout to preserve | Code review | Not applicable | Documented: no code rollback |
| Static analysis | n/a | Slither 0.11.3, per file (`AgentAccount.sol`; `AgentAccountFactory.sol`, which compiles the registry), `lib/` filtered; whole-repo mode fails on duplicate `ERC20` names | `bash script/run-slither.sh` (offline, about 15 s; in the gate when Slither 0.11.3 is installed); triage in [`docs/reports/2026-10-09-agent-accounts-slither.md`](reports/2026-10-09-agent-accounts-slither.md) | Pass at `86cc00d`: 87 results (50 + 37), per target and detector equal to the triaged baseline; 0 true positives | None |
| Independent review and external audit | n/a | Required by spec 10 before testnet and mainnet respectively | n/a | Pending (the branch's final review approved the code for testnet at `6a559b3`, before the move) | Both |

### Spec 10 fork cases

`test/integration/AgentLaunchFork.t.sol` proves spec 10's remaining fork cases at testnet block 66,497,000 against
the deployed agent factory and registry and the deployed Launch contracts. The curve it buys up is a real testnet launch
(`0x93f8…03F1`, in `Trading` at that block). Two execution modes:

- **Foundry fork**, for the paths that move only native value:
  - a **launch with an initial buy**: the account is the creator at Launch's FeeManager; the referrer bound at account
    creation is the one paid on the initial buy's fee, and the launch locks the binding; an account without a referrer
    leaves the referral share with the platform for good; a referrer equal to the account's own address is refused at
    creation;
  - a **creator fee claim** (`claimFees`): the whole claim lands in the account itself, and neither the owner nor the
    agent receives anything.
- **Arc's node**, through `eth_call` at the same block, for the paths that move USDC or need the blocklist. Arc's USDC
  at `0x3600…0000` moves value through the Native Coin Authority precompile (`0x1800…0000`), and its blocklist lives in
  the Native Coin Control precompile (`0x1800…0001`). A Foundry fork has neither, so on a fork every USDC transfer
  reverts, graduation included, and nobody can be blocklisted. These cases are not modelled. A scenario contract
  (`test/utils/AgentLiveScenario.sol`) is placed by state override and run by Arc's node against the live state; the
  test asserts the result, and nothing persists:
  - a **graduating buy**: the agent's buy completes the curve and graduates it in the same call. The account is charged
    its measured native delta, refund netted and rounded up to usdc6, and its basis holds the remaining supply;
  - a **sell during `GraduationPending`**: the real USDC blocklister blocklists the GraduationManager, so the agent's
    completing buy leaves the curve `GraduationPending`. A buy is refused `NotTrading`, and the sell is charged its
    basis value and reopens `Trading`. Once the blocklisting is lifted, the next completing buy graduates the curve;
  - a **blocklisted-owner withdraw**: the real blocklister blocklists the owner. `withdraw` (native and the USDC ERC-20
    view), `withdrawMany` and the agent's `sweepToOwner` all revert at Arc's blocklist. The agent cannot withdraw, take
    ownership or sweep USDC through its ERC-20 view, and the account's balance is untouched. Launch tokens are outside
    the USDC blocklist and still withdraw. An EOA on Arc testnet's seeded blocklist cannot even submit the call: the
    node refuses it (spec Q9: nothing can override this);
  - the **real USDC approve and Permit2 path**: after a graduation, a pool buy and sell through the deployed Universal
    Router use Arc's real USDC `approve`, Permit2 allowance and `transferFrom`. Both views of the balance agree, the
    spend is the native delta, and every allowance is back to zero.

The testnet smoke still records transaction hashes for these flows on the live chain; a mainnet fork follows once the
accounts are deployed on mainnet.

## 11. Open gaps (pending before contract readiness)

- Independent internal multi-auditor review of the whole agent contract set, then an external audit before mainnet
  (spec 10). No mainnet deployment with an open finding.
- Live runtime comparison after the testnet deployment (`verify-agent-accounts.py --rpc ... --block ... --record`).
- Spec 10's fork cases on a mainnet fork, once the accounts are deployed on mainnet (the testnet cases pass; section
  10, "Spec 10 fork cases").
- Mainnet per-tx gas cap probe and mainnet constructor simulation (no public mainnet RPC reachable read-only on
  9 October 2026).
- Owner decisions D1 to D8 were taken at the spec's recommendations; a different choice costs a contract change before
  testnet.
