"""Runtime identity helpers shared by the agent accounts verifier: immutable naming, substitution, the byte-for-byte
mismatch report, and the reproduction of the pinned Universal Router runtime. No keys, no signing, no writes.

A built runtime (out/, deployedBytecode + immutableReferences) is rebuilt with every immutable substituted by name and
compared byte for byte with the runtime under test. Every immutable must be named and supplied; a different immutable
set in either direction is a reviewed-source change and is refused.
"""
import json
import subprocess
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
# The only immutables each contract may carry, filled in by the verifier.
EXPECTED_IMMUTABLES = {}
ROUTER_REPORT = 'docs/reports/2026-09-27-universal-router-comparison.json'
ROUTER_OUT = 'out/universal-router'
ROUTER_ARTIFACT = f'{ROUTER_OUT}/UniversalRouter.sol/UniversalRouter.json'


def cast_keccak(raw):
    return subprocess.run(['cast', 'keccak', '0x' + raw.hex()], capture_output=True, text=True, check=True).stdout.strip()


def rpc_call(url, method, params):
    request = urllib.request.Request(
        url,
        json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
        {'content-type': 'application/json', 'user-agent': 'curl/8.7.1'},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.loads(response.read())
    if 'error' in body:
        raise SystemExit(f'{method}: {body["error"]}')
    return body['result']


def _collect_immutables(node, names):
    if isinstance(node, dict):
        if node.get('nodeType') == 'VariableDeclaration' and node.get('mutability') == 'immutable':
            names[str(node['id'])] = node['name']
        for value in node.values():
            _collect_immutables(value, names)
    elif isinstance(node, list):
        for value in node:
            _collect_immutables(value, names)


def immutable_names(artifact):
    names = {}
    _collect_immutables(artifact.get('ast', {}), names)
    # Inherited immutables are declared in other sources; resolve their ids against the sibling ASTs.
    needed = {str(k) for k in artifact['deployedBytecode']['immutableReferences']}
    if not needed <= set(names):
        for path in sorted((root / 'out').glob('*/*.json')):
            if needed <= set(names):
                break
            _collect_immutables(json.loads(path.read_text()).get('ast', {}), names)
    missing = needed - set(names)
    if missing:
        raise SystemExit(f'cannot name immutable ids {sorted(missing)}')
    return names


def address_word(address):
    return bytes(12) + bytes.fromhex(address.removeprefix('0x').rjust(40, '0'))


def uint_word(value):
    return value.to_bytes(32, 'big')


def is_address(text):
    return (isinstance(text, str) and len(text) == 42 and text[:2] == '0x'
            and all(c in '0123456789abcdefABCDEF' for c in text[2:]))


def expected_runtime(artifact, values, kind):
    """Return (expected bytes, immutable ranges). Values map immutable name to a 32-byte word."""
    code = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    names = immutable_names(artifact)
    found = {names[key] for key in artifact['deployedBytecode']['immutableReferences']}
    if found != EXPECTED_IMMUTABLES[kind]:
        raise SystemExit(
            f'{kind}: immutable set differs: unexpected {sorted(found - EXPECTED_IMMUTABLES[kind])}, '
            f'missing {sorted(EXPECTED_IMMUTABLES[kind] - found)}'
        )
    ranges = []
    for key, refs in artifact['deployedBytecode']['immutableReferences'].items():
        name = names[key]
        for ref in refs:
            start, length = ref['start'], ref['length']
            ranges.append((start, start + length, name))
            if name not in values:
                raise SystemExit(f'{kind}: no value supplied for immutable {name}')
            if length != 32 or len(values[name]) != 32:
                raise SystemExit(f'{kind}: immutable {name} is not one 32-byte word')
            code[start:start + length] = values[name]
    return bytes(code), ranges


def differing(expected, live):
    if len(expected) != len(live):
        return [f'length {len(live)} != expected {len(expected)}']
    return [i for i in range(len(live)) if expected[i] != live[i]]


def verify(label, kind, artifact, values, live):
    expected, ranges = expected_runtime(artifact, values, kind)
    diff = differing(expected, live)
    if diff:
        where = ''
        if isinstance(diff[0], int):
            hit = sorted({n for s, e, n in ranges if any(s <= o < e for o in diff)})
            where = f' (inside immutables: {", ".join(hit) or "none"})'
        print(f'{label}: MISMATCH at offsets {diff[:32]}{" ..." if len(diff) > 32 else ""}{where}')
        return False
    print(f'{label}: MATCH {len(live)} runtime bytes, keccak {cast_keccak(live)}')
    return True


def expect_rejected(label, artifact, values, kind):
    try:
        expected_runtime(artifact, values, kind)
    except SystemExit as error:
        print(f'{label}: rejected ({error})')
        return True
    print(f'{label}: NOT rejected')
    return False


def load(path):
    return json.loads((root / path).read_text())


# ------------------------------------------------------------------------------------------------- Universal Router


def router_names():
    names = {}
    for path in sorted((root / ROUTER_OUT).glob('*/*.json')):
        _collect_immutables(json.loads(path.read_text()).get('ast', {}), names)
    return names


def router_runtime(chain):
    """The reproduced router runtime for `chain`, its PERMIT2 offsets and the report's entry for that network.

    Rebuilt from the pinned router build (script/build-universal-router.sh) with every immutable taken from the router
    comparison report, which records the bytes observed on chain (sha256). Returns (runtime, permit2 offsets, report
    network entry, report immutables).
    """
    if not (root / ROUTER_ARTIFACT).is_file():
        raise SystemExit(f'{ROUTER_ARTIFACT} missing; run `bash script/build-universal-router.sh`')
    report = load(ROUTER_REPORT)
    artifact = load(ROUTER_ARTIFACT)
    names = router_names()
    proofs = {entry['chainId']: entry['immutables'] for entry in report['immutableProof']}
    network = next((n for n in report['networks'] if n['chainId'] == chain), None)
    if network is None or chain not in proofs:
        raise SystemExit(f'router report has no entry for chain {chain}')
    code = bytearray.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    offsets = []
    for key, refs in artifact['deployedBytecode']['immutableReferences'].items():
        value = bytes.fromhex(proofs[chain][names[key]].removeprefix('0x'))
        for ref in refs:
            if len(value) != ref['length']:
                raise SystemExit(f'router immutable {names[key]} has the wrong length')
            code[ref['start']:ref['start'] + ref['length']] = value
            if names[key] == 'PERMIT2':
                offsets.append(ref['start'])
    if not offsets:
        raise SystemExit('router artifact has no PERMIT2 immutable')
    return bytes(code), offsets, network, proofs[chain]


def check_router_code(live, manifest, label):
    """A router runtime is accepted when its keccak is the manifest's routerCodeHash and every PERMIT2 slot holds the
    manifest permit2. Prints and returns the verdict."""
    _, offsets, _, _ = router_runtime(manifest['chainId'])
    ok = True
    keccak = cast_keccak(live)
    if keccak.lower() != str(manifest.get('routerCodeHash', '')).lower():
        print(f'{label}: router code hash {keccak} != manifest routerCodeHash {manifest.get("routerCodeHash")}')
        ok = False
    word = address_word(manifest['permit2'])
    for offset in offsets:
        if live[offset:offset + 32] != word:
            print(f'{label}: router PERMIT2 at offset {offset} is 0x{live[offset:offset + 32].hex()}, '
                  f'not the manifest permit2')
            ok = False
    if ok:
        print(f'{label}: router code hash {keccak} and PERMIT2 at offsets {offsets} match the manifest')
    return ok
