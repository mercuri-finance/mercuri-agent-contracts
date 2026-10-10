// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Shared checks for the agent accounts deployment script on Arc testnet and Arc mainnet. Holds no key and
///         never broadcasts by itself.
/// @dev Launch's deployment records come from the pinned Launch submodule. The Universal Router each network's agent
///      manifest names is pinned here as well, address and runtime keccak, so a manifest edit alone cannot point the
///      accounts at another router; `verify-agent-accounts.py --preflight` reproduces the same runtime hash from the
///      pinned upstream router source and the bytes observed on chain (docs/reports/2026-09-27-universal-router-
///      comparison.json).
abstract contract AgentDeployBase is Script {
    uint256 internal constant TESTNET_CHAIN_ID = 5042002;
    uint256 internal constant MAINNET_CHAIN_ID = 5042;
    /// @dev Launch's tracked deployment records, `<chainId>.json`, from the pinned Launch submodule.
    string internal constant LAUNCH_RECORDS = "lib/mercuri-launch-contracts/deployments/";
    /// @dev The canonical Uniswap Universal Router on both Arc networks.
    address internal constant UNIVERSAL_ROUTER = 0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1;
    /// @dev Its runtime keccak on Arc testnet. The two networks differ only in the cached EIP-712 domain and chain id.
    bytes32 internal constant TESTNET_ROUTER_CODE_HASH =
        0xd09ab86ed043d4d3343535423cac90eec597d489ad6e33780291fdc5d68ac84b;
    /// @dev Its runtime keccak on Arc mainnet.
    bytes32 internal constant MAINNET_ROUTER_CODE_HASH =
        0x7f949fe75d3483670e17a9ab398a3dc71f285026bba755b48fffd1e42aefad71;

    error WrongChain(uint256 chainId);
    error NotArcNode(string clientVersion);
    error NoCode(string name, address account);
    error LaunchRecordMismatch(string field);
    error RouterMismatch(string what);
    error DeploymentMismatch(string what);

    /// @dev Refuses any chain other than Arc testnet and Arc mainnet. A local fork keeps its network's chain id, so it
    ///      reads that network's manifest and Launch record.
    function _requireArc() internal {
        if (block.chainid != TESTNET_CHAIN_ID && block.chainid != MAINNET_CHAIN_ID) revert WrongChain(block.chainid);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _requireArcOrAnvilNode(vm.rpc("web3_clientVersion", "[]"));
        }
    }

    /// @dev A broadcast must reach an Arc node or a loopback Anvil fork: any other client that reports an Arc chain id
    ///      (a hosted simulator, another dev node) would write broadcast files indistinguishable from a real deploy.
    function _requireArcOrAnvilNode(bytes memory clientVersion) internal pure {
        // The cheatcode returns the version bare; a JSON-quoted one is accepted too.
        uint256 offset = clientVersion.length > 0 && clientVersion[0] == '"' ? 1 : 0;
        if (!_startsWith(clientVersion, offset, bytes("arc/")) && !_startsWith(clientVersion, offset, bytes("anvil/")))
        {
            revert NotArcNode(string(clientVersion));
        }
    }

    function _startsWith(bytes memory haystack, uint256 offset, bytes memory prefix) internal pure returns (bool) {
        if (offset + prefix.length > haystack.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (haystack[offset + i] != prefix[i]) return false;
        }
        return true;
    }

    /// @dev Launch's deployment record for the current chain.
    function _launchRecord() internal view returns (string memory) {
        return vm.readFile(string.concat(LAUNCH_RECORDS, vm.toString(block.chainid), ".json"));
    }

    /// @dev The pinned router runtime keccak for the current chain (zero off Arc).
    function _routerCodeHashPin() internal view returns (bytes32) {
        if (block.chainid == TESTNET_CHAIN_ID) return TESTNET_ROUTER_CODE_HASH;
        if (block.chainid == MAINNET_CHAIN_ID) return MAINNET_ROUTER_CODE_HASH;
        return bytes32(0);
    }

    /// @dev The Universal Router keeps its permit2 in an internal immutable with no getter, so its runtime is pinned by
    ///      the manifest's `routerCodeHash`, which must equal the pin above. `verify-agent-accounts.py --preflight`
    ///      proves that runtime is the pinned router source with the manifest's permit2 in its PERMIT2 immutable.
    function _requireRouter(address router, string memory manifest) internal view {
        if (router.code.length == 0) revert NoCode("router", router);
        if (router.codehash != vm.parseJsonBytes32(manifest, ".routerCodeHash")) revert RouterMismatch("codehash");
    }

    function _requireCode(string memory name, address account) internal view {
        if (account.code.length == 0) revert NoCode(name, account);
    }
}
