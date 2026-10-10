#!/usr/bin/env bash
# Build the pinned upstream Uniswap Universal Router that the agent tests and the loopback deployment run against.
#
#   bash script/build-universal-router.sh
#
# The router is not part of this repository's compiler profiles: it builds with its own settings (Solidity 0.8.26,
# Cancun, via-IR, optimizer 4444, no metadata hash; script/universal-router/foundry.toml). Its 110-file compiler import
# closure is assembled in a temporary directory from the pinned submodules (lib/universal-router at 999d561 with its
# own submodules, lib/uniswap-v2-core at v1.0.1 and lib/uniswap-v3-core at v1.0.0, the npm versions the router's
# package.json pins), and every file's keccak256 must equal script/universal-router/source-manifest.json before
# anything is compiled. The temporary tree has the layout the manifest names, so the build is the one whose runtime
# docs/reports/2026-09-27-universal-router-comparison.json matched byte for byte on both Arc networks.
# Output: out/universal-router/. No network, no RPC, no keys.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

work=$(mktemp -d -t mercuri-universal-router)
trap 'rm -rf "$work"' EXIT

python3 - "$root" "$work" << 'EOF'
import json, shutil, subprocess, sys
from pathlib import Path

root, work = Path(sys.argv[1]), Path(sys.argv[2])
config = root / 'script' / 'universal-router'
manifest = json.loads((config / 'source-manifest.json').read_text())
# Closure path prefix -> pinned submodule directory. Everything else lives in the router submodule itself.
SOURCES = {'lib/v2-core/': 'lib/uniswap-v2-core/', 'lib/v3-core/': 'lib/uniswap-v3-core/'}
pinned = {
    'lib/universal-router': manifest['revision'],
    'lib/uniswap-v2-core': '4dd59067c76dea4a0e8e4bfdda41877a6b16dedc',
    'lib/uniswap-v3-core': 'e3589b192d0be27e100cd0daaf6c97204fdb1899',
}
for path, want in pinned.items():
    got = subprocess.run(['git', '-C', str(root / path), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    if got.returncode or got.stdout.strip() != want:
        raise SystemExit(f'{path} is not at {want}; run `git submodule update --init --recursive`')
for name, want in sorted(manifest['sources'].items()):
    prefix = next((p for p in SOURCES if name.startswith(p)), None)
    source = root / (SOURCES[prefix] + name[len(prefix):] if prefix else 'lib/universal-router/' + name)
    if not source.is_file():
        raise SystemExit(f'{name}: {source.relative_to(root)} missing; run `git submodule update --init --recursive`')
    data = source.read_bytes()
    got = subprocess.run(['cast', 'keccak', '0x' + data.hex()], capture_output=True, text=True, check=True).stdout
    if got.strip().lower() != want.lower():
        raise SystemExit(f'{name}: keccak differs from script/universal-router/source-manifest.json')
    target = work / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
for name in ('foundry.toml', 'remappings.txt'):
    shutil.copy(config / name, work / name)
print(f'Universal Router closure: {len(manifest["sources"])} sources match the manifest '
      f'(Uniswap/universal-router {manifest["revision"]})')
EOF

forge build --root "$work" contracts/UniversalRouter.sol \
  --out "$root/out/universal-router" --cache-path "$root/cache/universal-router"
