# Security

## Reporting a vulnerability

Use GitHub's private reporting: **Security → Report a vulnerability** on this repository. The report is visible only to
the maintainers until a fix is deployed and disclosed. Please do not open a public issue for anything that could be
exploited.

Include the contract and function, the chain (testnet 5042002 or mainnet 5042), a transaction or a Foundry test that
shows the behaviour, and what you think the impact is. You will get an acknowledgement within 48 hours and updates as
the fix moves.

## Scope

The contracts in `src/`, `AgentAccount`, `AgentAccountFactory` and the `AgentPolicyRegistry` the factory deploys, and
the deployment and verification scripts in `script/`. Nothing is deployed yet; once it is, the scope is the addresses
in the deployment records under `deployments/` and the accounts their factories create. The dependencies under `lib/`
are upstream code, and Launch's contracts are in their own public repository; report defects in them there as well.

Out of scope: the web app, the SDK, the API and the hosting, which are not in this repository; and findings that
require a compromised owner key, or Launch's governance acting maliciously, which the security model treats as trust
boundaries rather than defects. A stolen agent key is in scope: what it can lose is bounded below, and a way past that
bound is a defect.

## Trust and governance

| Component | Mutability | Who controls what |
| --- | --- | --- |
| `AgentAccount` (implementation and every clone) | Immutable: EIP-1167 clones of one implementation, no upgrade, delegatecall, generic execute or selfdestruct | The account's owner withdraws (only to itself) and manages it through the registry; the owner has no trade path. Agent keys call the typed trade functions only, within the owner's policy. Nobody else can move the account's funds. |
| `AgentPolicyRegistry` | Immutable, one per factory, no admin and no owner of its own | Each account's owner, for that account only. It trusts its factory to register accounts and each registered account to authorize and record its own calls. |
| `AgentAccountFactory` | Immutable; holds no funds | The admin (Launch's timelock on the same network) can replace the guardian and lift, shorten or extend an active pause to at most 30 days from now; it cannot start a pause or touch an account, a policy or funds. The guardian (the Guardian Safe on mainnet) can pause agent functions of every account for 72 hours, then must wait 72 hours. A pause stops agent functions only. |
| Agent key | Off-chain key the owner adds, with an expiry of at most 180 days and a permission mask | Trades through the account within the policy. It can never withdraw, change the policy or add an agent. |
| Launch's LaunchFactory, FeeManager and GraduationManager | Upgradeable proxies behind Launch's timelock (48-hour delay on mainnet) | Trusted, as by every Launch trader: the account derives every curve and pool from them at execution time. A malicious Launch upgrade could make an account treat a fake curve or pool as genuine. |

What a stolen agent key can lose, per period of the account's policy: at most `periodSpendCap` of USDC on bad buys
(at most `perTokenPeriodCap` on any one token) plus holdings worth at most `periodSellCap` valued at what the account
paid, every action also capped at `maxTradeUsdc`. Periods are fixed windows, so twice that across a boundary, and the
total keeps accruing until the key is revoked, expires or agents are paused. Sell proceeds and fee claims never create
headroom. The full statement, with the default and beta-ceiling figures, is in
[`docs/agent-accounts.md`](docs/agent-accounts.md), section 3.

Limits a reviewer should know:

- Tokens received from outside (airdrops, transfers in, tokens beyond the recorded amount) have no cost basis; they are
  valued at the pre-trade curve quote, or at the measured proceeds on a pool, which an attacker can move. The sell cap
  does not protect them; owners should withdraw them.
- The price-impact limit measures the account's own trade from the already-moved price. It is not a sandwich defence;
  against a stolen key the caps are the control.
- Widening an account (a new agent, a higher cap, an allowlisted token, a shorter delay, a new owner) waits the
  account's delay, at most 7 days, so a phished owner is slowed, not stopped. The owner can cancel a queued item, a
  pause cancels them, and every item expires 7 days after it becomes executable.
- The admin can keep agents paused indefinitely by extending an active pause before it ends; each extension is its own
  timelock operation, publicly queued, and owners' withdrawals keep working throughout.
- `withdrawMany` of more than about 200 cold tokens does not fit Arc's per-transaction gas cap of 16,777,216; exits are
  chunked (the SDK sends 100 tokens per transaction). There is no on-chain token list a stolen key could inflate.
- A USDC blocklist on the owner's address blocks that owner's withdrawals of USDC; nothing in these contracts can
  override it.

## Pause and recovery

The guardian pause stops agent functions of every account for 72 hours; each owner can also pause their own agents
at any time. Neither stops the owner's withdrawals, revocations or policy tightening. There is no rescue function and
no admin over funds: assets reach the owner only through `withdraw`, `withdrawMany` or an agent's `sweepToOwner`.

## Replacement

All three contracts are immutable. A fix is a new implementation and a new factory with its registry; owners migrate
by pausing or revoking their agents, withdrawing everything, and creating an account on the new factory. The old
factory keeps working. There is no code rollback. The steps are in [`docs/agent-accounts.md`](docs/agent-accounts.md),
section 6.

## What already exists

- Release evidence: [`docs/agent-accounts.md`](docs/agent-accounts.md), section 10, and the triaged static analysis
  in [`docs/reports/`](docs/reports).
- Reproducible bytecode: `python3 script/verify-agent-accounts.py` after `forge build`, for the implementation, the
  factory and the registry, every immutable reconstructed from the manifest and the deployment record. Until a
  deployment record exists it runs in `--self-test`, `--preflight` and `--simulate` mode against the freshly built
  artifacts, the manifests and Launch's deployment records.
- The deployment script refuses to finish unless the implementation, factory and registry land at their predicted
  addresses, wired exactly as the manifest says.

The contract set was reviewed before it moved to this repository, and the final review approved it for testnet. These
were AI-assisted reviews; an independent review of the whole set is required before testnet sign-off and an external
audit before mainnet. No professional third-party audit has been performed yet.
