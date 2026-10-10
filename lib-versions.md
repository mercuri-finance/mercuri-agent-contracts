# Dependencies (public Git submodules, pinned by commit)

| Path | Package | Version |
| --- | --- | --- |
| `lib/mercuri-launch-contracts` | mercuri-finance/mercuri-launch-contracts | Git submodule at `99d7c28a19e254e5c1cf0444819ddabae3e9c469` |
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts | v5.4.0, `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` |
| `lib/forge-std` | foundry-rs/forge-std | `5e3854938622a1bc23906020aedc8ce6df61be59` (1.16.2 and later) |
| `lib/universal-router` | Uniswap/universal-router | 2.1.1, `999d561c3ad58fb5cab91b602911f3c75591a9c7`, with its own submodules |
| `lib/uniswap-v2-core` | Uniswap/v2-core | v1.0.1, `4dd59067c76dea4a0e8e4bfdda41877a6b16dedc` |
| `lib/uniswap-v3-core` | Uniswap/v3-core | v1.0.0, `e3589b192d0be27e100cd0daaf6c97204fdb1899` |

Clone with `git clone --recurse-submodules`, or run `git submodule update --init --recursive` in a checkout;
`git submodule status` shows the pins.

`lib/mercuri-launch-contracts` is the public
[mercuri-launch-contracts](https://github.com/mercuri-finance/mercuri-launch-contracts) repository at the commit above.
It brings the deployed Launch sources the accounts call, Launch's deployment records (read by the deployment script,
the preflight and the tests), and the Uniswap v4, Permit2 and OpenZeppelin upgradeable trees Launch vendors (see its
own `lib-versions.md`); the remappings reach them inside the submodule. Launch vendors OpenZeppelin and forge-std as
plain files with no upstream revision, so this repository pins the upstream commits whose trees equal them:
OpenZeppelin `contracts/` at Git tree `3ad914f1d52dac76a5c357842229f7e6370c4a2a` and forge-std `src/` at Git tree
`a1d019ea9864f0928fde45b565e8292c738daa98`, the same trees as Launch's vendored copies.

The Launch test scaffolding under `test/utils/` and `test/utils/launch/` (the Launch and Uniswap v4 fixtures, the
native USDC shim, the hook miner and the default configuration) was copied from Launch's test tree, through the
Mercurifi Trade repository, on 10 October 2026; keep it in step with Launch when that tree changes.

## Universal Router

`lib/universal-router` pins Uniswap/universal-router `999d561c3ad58fb5cab91b602911f3c75591a9c7` (2.1.1), the revision
behind Arc's router `0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1` on both networks. `lib/uniswap-v2-core` and
`lib/uniswap-v3-core` are the npm versions the router's `package.json` pins. The deployed contracts do not compile
against the router: they call it through a one-function interface in `src/AgentAccount.sol`. It is built only for the
tests and the loopback deployment.

`bash script/build-universal-router.sh` checks the three submodule commits, assembles the router's 110-file compiler
import closure in a temporary directory, requires every file's keccak256 to equal
`script/universal-router/source-manifest.json`, and builds it with its own settings (Solidity 0.8.26, Cancun, via-IR,
optimizer 4444, no metadata hash; `script/universal-router/foundry.toml`) into `out/universal-router/`. With the
immutables recorded in `docs/reports/2026-09-27-universal-router-comparison.json`, that build reproduces the deployed
runtime on both networks, whose keccak is each manifest's `routerCodeHash`.

## Reproducible source identity

| Item | Identity |
| --- | --- |
| `lib/mercuri-launch-contracts` | submodule commit `99d7c28a19e254e5c1cf0444819ddabae3e9c469` |
| `lib/universal-router` closure | 110 files, keccak256 in `script/universal-router/source-manifest.json`, checked by `script/build-universal-router.sh` |
| `src/` (accounts, factory, registry, libraries, interfaces) | sha256 in `source-manifest.json`, checked by `script/check-local-source.py` |

Build with Solidity 0.8.26, Cancun, via-IR and the per-path optimizer profiles in `foundry.toml`. The executable used
for the release evidence identifies itself as Foundry 1.4.3-Homebrew, build timestamp `2025-10-22T03:58:23Z`; it
reports `VERGEN_IDEMPOTENT_OUTPUT` instead of an upstream commit. Its SHA-256 is
`7a91e6efdcbb02203367c2c8c7e54928b7d1f3c6e636f7393c73b6201a9020c6`.
