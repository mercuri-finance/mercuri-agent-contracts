# Mercurifi Agent Accounts: contracts

Status: candidate, **not deployed** on either network. Authoritative design: the agent accounts spec of 9 October 2026
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
  [`AgentAttacks.t.sol`](../test/AgentAttacks.t.sol) asserts a 200-entry `withdrawMany` runs under a
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
| Agent pool buy through the deployed testnet Universal Router and LaunchHook (fork, first action, cold; measured at `6a559b3`) | 420,219 |
| Agent pool sell, same pool (fork; measured at `6a559b3`) | 235,046 |
| `createAccount` with referrer binding and a first agent | 353,719 |
| Graduating agent buy, minimum call gas (cold) | 1,254,882 |
| `revokeAgent` | 45,879 |
| `withdrawMany` of 200 tokens / 501 tokens | 7,245,580 / 18,200,591 |
| Deploy implementation and factory (with registry), including the script's checks | 7,614,095 |

`createAccount` is above the spec's 200 to 250k planning figure: since the 9 Oct registry split it writes the full
policy, the first agent and the usage slots into the registry. At Arc gas prices this is a fraction of a cent.

## 9. Deployment

Inputs only, per network: [`deployments/agent-accounts-manifest-5042002.json`](../deployments/agent-accounts-manifest-5042002.json)
and [`deployments/agent-accounts-manifest-5042.json`](../deployments/agent-accounts-manifest-5042.json). Launch
addresses come from Launch's deployment record for the chain, the Universal Router and its runtime hash are the pins in
[`script/AgentDeployBase.sol`](../script/AgentDeployBase.sol) (reproduced by the preflight from the pinned upstream
router source and the bytes observed on chain, [`docs/reports/2026-09-27-universal-router-comparison.json`](reports/2026-09-27-universal-router-comparison.json)),
`admin` is the network's Launch timelock, `guardian` is the record's guardian (the Guardian Safe on
mainnet, the testnet guardian key on testnet), and the ceilings are exactly spec 4.5. No deployed address is in them.

[`script/DeployAgentAccounts.s.sol`](../script/DeployAgentAccounts.s.sol) checks the manifest against those records
and the beta ceilings, requires code at every dependency and the pinned router runtime (and, on mainnet, a guardian
contract), predicts the implementation, factory and registry addresses from the deployer's nonce, deploys the
implementation and then the factory, and refuses to finish unless all three land where predicted and every immutable
and getter matches the manifest (`EXPECTED_AGENT_FACTORY` optionally pins the factory address). A deployment needs its
own owner go per network (decision D9); no task runs it with `--broadcast`.

After a broadcast, [`script/write-agent-accounts-record.py`](../script/write-agent-accounts-record.py) writes
`deployments/agent-accounts-<chainId>.json` from forge's completed broadcast file, and only from that: no pending
transaction, exactly the implementation then the factory, both CREATEs from one sender at consecutive nonces with
status-1 receipts, the broadcast's chain and commit matching, the constructor arguments equal to the manifest (the
implementation naming the factory and the factory's first CREATE as registry), each input the built creation code with
those arguments, and the registry created by the factory at its predicted address from the built registry code; the
manifest must first pass the verifier's preflight. It refuses anything else and never overwrites a record: the record is
written to a temporary file and hard-linked into place, which fails if the name exists, so a record written by a
racing run is never replaced. Its `--self-test` (54 cases, in the gate) covers each refusal. No record exists: nothing
has been deployed.

Then `python3 script/verify-agent-accounts.py --rpc <Arc RPC> --block <n> --record deployments/agent-accounts-<chainId>.json`
reads only that record (the writer's file name, key set and version, every input equal to the manifest), refuses a
block before the record's `factoryDeployBlock` (where every runtime is empty), rebuilds the
three runtimes from `out/` with the manifest and record values in every immutable and compares them byte for byte with
`eth_getCode`, checks the registry is the factory's first CREATE, the router's code hash and the factory's guardian;
`--account <addr>` also checks one clone.

## 10. Release evidence

Candidate: this repository after the repo-parity step (NatSpec edits in `src/`, which change the metadata hash). The
evidence rows below are **pending final run after parity**; the move itself was checked at the initial commit
`f11162d` (gate exit 0, byte-identical bytecode, Universal Router pin reproduced). The sources were moved from
mercuri-trade-contracts at `5f71ef5`, where the code candidate was `6a559b3` and the independent final review approved it for testnet; `src/`
is unchanged (same sha256 for all eight files), and rebuilding here at `f11162d` gave creation and runtime code for
`AgentAccount`, `AgentAccountFactory` and `AgentPolicyRegistry` byte-identical to the build at `5f71ef5` (with
`bytecode_hash = "none"` the only CBOR is the compiler version, so stripping it changes nothing). The move changed the
deploy script and the verifier only where they read the Trade manifest: the Universal Router address and runtime hash
are now pinned in `script/AgentDeployBase.sol` and in the agent manifests, and the preflight reproduces that hash from
the pinned upstream router source. Baseline: Launch as pinned in `lib/mercuri-launch-contracts` at `99d7c28` and its
deployment records for 5042002 and 5042; the deployed Universal Router `0x4fcA…9Fb1` at its pinned runtime hash.
Toolchain: forge 1.4.3, solc 0.8.26, Cancun, via-IR, 200 optimizer runs for `src/**`, no metadata hash. Missing
evidence is pending, not pass.

| Requirement | Baseline | Candidate | Command or artifact | Result | Open gap |
| --- | --- | --- | --- | --- | --- |
| Source manifest | n/a | All eight `src/` sources listed with sha256, identical to the reviewed sources | `python3 script/check-local-source.py` (in gate) | Pending final run after parity | None |
| Bytecode identity after the move | Build at mercuri-trade-contracts `5f71ef5` | Build here at `f11162d` | `deployedBytecode` and `bytecode` of the three contracts compared, with and without the trailing CBOR | Byte-identical (runtime 15,387 / 3,855 / 17,838 B); immutable offsets identical | None |
| NatSpec | n/a | `AgentAccount`, `AgentAccountFactory`, `AgentPolicyRegistry` and their three interfaces | `python3 script/check-natspec.py` | Pending final run after parity | Semantic review of NatSpec is part of the independent review |
| Runtime identity | n/a | Every immutable of the implementation (10), factory (14) and registry (1) reconstructed; a flipped byte in each is rejected by name; extra or missing immutables refused; EIP-1167 clone check | `python3 script/verify-agent-accounts.py --self-test`, ten `--self-test-flipped` pairs (in gate) | Pending final run after parity | Live comparison against a real deployment is pending until a testnet deployment exists |
| Substitution correctness | n/a | Constructor simulations (`eth_call`, no transaction) of the built creation code with the testnet manifest inputs equal the reconstructed runtimes | `python3 script/verify-agent-accounts.py --simulate --block 66465327` against `https://rpc.testnet.arc.io` | Pending final run after parity | Mainnet simulation pending (no public mainnet RPC reachable) |
| Universal Router pin | n/a | `out/universal-router` rebuilt from the pinned submodules (110-file closure, every keccak checked) is byte-identical to the build the router comparison report matched on chain; with the report's immutables it reproduces the observed runtime (sha256) on both networks, whose keccak is each manifest's `routerCodeHash` with the manifest permit2 in every PERMIT2 slot | `bash script/build-universal-router.sh`; `verify-agent-accounts.py --preflight` (in gate) | Pass | None |
| Manifests | n/a | Inputs only (extra keys refused by the script and the preflight); Launch addresses = Launch records, admin = timelock, guardian = record guardian, router and hash = the pins and the reproduced router, ceilings = spec 4.5 | `verify-agent-accounts.py --preflight` for both; a raised-ceiling copy and a testnet copy with the mainnet router hash refused (in gate); `DeployAgentAccounts.t.sol` | Pending final run after parity | Mainnet guardian code check runs only at deploy time (script requires code on 5042) |
| Deploy script | n/a | Predicts implementation, factory and registry from the deployer nonce; full wiring check; wrong chain and missing code refused; tampered manifests refused by field, including the other network's router hash | `test/DeployAgentAccounts.t.sol` (6 tests, in process against the fixture, never broadcast); the fork test runs `run()` against deployed testnet Launch; `forge script script/DeployAgentAccounts.s.sol --rpc-url https://rpc.testnet.arc.io` (no `--broadcast`, sender `0x…0a6e47`) | Pending final run after parity | Testnet deployment needs an owner go (D9) |
| Deployment record writer | n/a | `write-agent-accounts-record.py`: writes `agent-accounts-<chainId>.json` only from a completed broadcast and only for a manifest that passes the preflight; links the record into place so an existing or racing record is never overwritten; names only HEAD of a clean tree as `sourceRevision`; the verifier's live mode reads only that record and refuses a block before `factoryDeployBlock` | `python3 script/write-agent-accounts-record.py --self-test` (in gate) and the verifier's record self-test | Pending final run after parity | Run against the real broadcast at the testnet deployment |
| Behaviour, attack, fuzz, invariant tests | n/a | 213 agent tests | `bash script/check-contracts.sh` (seed `0x5042`) | Pending final run after parity | None |
| Stress | n/a | Gate with `--stress`: 10,000-run fuzz pass (fork suite included), then the agent invariants alone at 1,024 x 256 with their own counterexample directory | `ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io AGENT_FORK_CHAIN_ID=5042002 AGENT_INVARIANT_STATS=true bash script/check-contracts.sh --stress` | Pending final run after parity | None |
| Pinned fork | n/a | Agent pool buy and sell (ERC-20 and Permit2 allowances back to zero; Alchemy URLs refused) through the deployed testnet Universal Router and LaunchHook on graduated token `0x97B4…eE84` at block 65,301,435, account deployed by the production script | `ARC_LOCAL_FORK_RPC=https://rpc.testnet.arc.io forge test --match-contract AgentPoolForkTest` (skipped without `ARC_LOCAL_FORK_RPC`) | Pending final run after parity | Spec 10's other fork cases and a mainnet fork: see "Before testnet sign-off" below |
| Gas | n/a | Snapshot `.gas-snapshot` (193 entries); identical to the reviewed snapshot except the four `DeployAgentAccountsTest` entries, whose test no longer reads a Trade manifest | `forge snapshot --check ...` (in gate) | Pending final run after parity | None |
| Size | EIP-170 24,576 B | 15,387 / 3,855 / 17,838 B | `forge build --sizes` | Pass | None |
| Arc per-tx gas cap | Unverified (ruling: likely 16,777,216) | Verified on testnet (section 7) | `eth_estimateGas` probe, block 66,330,102 | 16,777,216 | Mainnet probe pending |
| Upgradeability and storage | n/a | No proxies; nothing to upgrade, no storage layout to preserve | Code review | Not applicable | Documented: no code rollback |
| Static analysis | n/a | Slither 0.11.3, per file (`AgentAccount.sol`; `AgentAccountFactory.sol`, which compiles the registry), `lib/` filtered; whole-repo mode fails on duplicate `ERC20` names | `bash script/run-slither.sh` (offline, about 15 s; in the gate when Slither 0.11.3 is installed); triage in [`docs/reports/2026-10-09-agent-accounts-slither.md`](reports/2026-10-09-agent-accounts-slither.md) | Pending final run after parity | None |
| Independent review and external audit | n/a | Required by spec 10 before testnet and mainnet respectively | n/a | Pending (the branch's final review approved the code for testnet at `6a559b3`, before the move) | Both |

### Before testnet sign-off

The pinned fork test proves the graduated pool buy and sell only. Spec 10's remaining fork cases are proven in the
testnet smoke, against the deployed testnet Launch contracts and the new testnet factory, before the testnet is signed
off:

- a **graduating buy**: the agent curve buy that graduates the curve, charged at its measured native delta (refund
  included) against the caps;
- a **sell during `GraduationPending`** (and a buy refused with `NotTrading` in the same state);
- a **launch with an initial buy**, with the creator and the referrer bound at Launch's FeeManager;
- a **fee claim** (`claimFees`) of the account's creator fees;
- a **blocklisted-owner withdraw**, expected to revert (spec Q9: a blocklisted owner cannot withdraw and nothing can
  override it); the live blocklist is not ours to set, so this case runs on a testnet fork that impersonates USDC's
  blocklister;
- the **real USDC approve and Permit2 path**: the pool trade's ERC-20 approval and Permit2 allowance against Arc's real
  USDC system contract, both back to zero after the trade.

Each case records the transaction hash and gas in the testnet smoke report; a mainnet fork follows before mainnet.

## 11. Open gaps (pending before contract readiness)

- Independent internal multi-auditor review of the whole agent contract set, then an external audit before mainnet
  (spec 10). No mainnet deployment with an open finding.
- Live runtime comparison after the testnet deployment (`verify-agent-accounts.py --rpc ... --block ... --record`).
- The remaining spec 10 fork cases (section 10, "Before testnet sign-off") in the testnet smoke, and a mainnet fork.
- Mainnet per-tx gas cap probe and mainnet constructor simulation (no public mainnet RPC reachable read-only on
  9 October 2026).
- Owner decisions D1 to D8 were taken at the spec's recommendations; a different choice costs a contract change before
  testnet.
