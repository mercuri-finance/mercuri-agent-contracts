# Contributing

This public repository owns the Mercurifi Agent Accounts contracts, their tests and release tooling. Nothing here is
deployed yet; once it is, anyone can read the code behind the addresses, rebuild it and check the bytecode. The
contracts are immutable, so a change to a deployed contract is a new reviewed release, a new deployment and a migration
for owners. Pull requests are reviewed, but merging one never authorizes a contract transaction.

## What is welcome

- **Security reports** — privately, through **Security → Report a vulnerability**. See [`SECURITY.md`](SECURITY.md).
- **Issues** for anything else you find: a mismatch between the code and what the README or the docs say, a build
  that does not reproduce, a link that does not resolve, an integration question (events, the SDK). Include the commit
  you built and, for on-chain behaviour, a transaction hash.
- **Corrections to the documentation** are welcome as issues too; they are folded into the next update.

## What a change needs

- **Tests.** A change to `src/` comes with its tests; `bash script/check-contracts.sh` must pass, and
  `--stress` against Arc's public RPC or a loopback fork of it before anything that touches funds or caps.
- **Pins.** Every dependency is a submodule pinned by commit. A new pin is deliberate, recorded in `lib-versions.md`
  with its commit and reason; the Universal Router closure must keep matching
  `script/universal-router/source-manifest.json`.
- **Launch.** Launch's contracts are a dependency, never edited here. If the accounts need something from Launch, it is
  a Launch release first.

## Building

```sh
git clone --recurse-submodules https://github.com/mercuri-finance/mercuri-agent-contracts.git
cd mercuri-agent-contracts
bash script/build-universal-router.sh
forge build
bash script/check-contracts.sh
# Read-only checks against a network, after a build:
python3 script/verify-agent-accounts.py --simulate --rpc https://rpc.testnet.arc.io
```

`forge build` uses the pinned toolchain in `foundry.toml` and the pinned submodules under `lib/`. The contract gate
also needs Python 3; it checks the source manifest, formatting, NatSpec, the record writer's and the runtime verifier's
offline self-tests and both manifests, then runs the tests, the gas snapshot and, when installed, Slither 0.11.3.
