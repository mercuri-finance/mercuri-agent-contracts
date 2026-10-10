// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {LaunchFactory} from "@mercuri/launch/LaunchFactory.sol";
import {GraduationManager} from "@mercuri/launch/GraduationManager.sol";
import {AgentAccount} from "../../src/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/AgentAccountFactory.sol";
import {AgentPolicyRegistry} from "../../src/AgentPolicyRegistry.sol";
import {InitParams, P_ALL} from "../../src/libraries/AgentTypes.sol";

/// @dev Arc's USDC blocklist entry points (Circle FiatToken roles), called as the real blocklister.
interface IUsdcBlocklist {
    function blacklist(address account) external;
    function unBlacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
}

/// @dev The deployed addresses a live scenario drives, all from `deployments/5042002.json`.
struct LiveAddrs {
    address agentFactory;
    address launchFactory;
    address feeManager;
    address graduationManager;
    address poolManager;
    address permit2;
    address usdc;
}

/// @dev Case 1: an agent curve buy that completes the curve and graduates it.
struct GraduationResult {
    uint8 phaseAfter;
    uint256 remainingBefore;
    uint256 quotedUsedWei;
    uint256 tokensOut;
    uint256 deltaWei;
    uint64 spent;
    uint64 tokenSpent;
    uint32 actions;
    uint128 basisCost;
    uint128 basisTokens;
    uint160 poolSqrtPriceX96;
    uint256 gas;
}

/// @dev Case 2: graduation deferred by a real USDC blocklisting of the GraduationManager, then an agent sell while
///      `GraduationPending`, then a retry once the blocklisting is lifted.
struct PendingResult {
    uint8 phaseAfterCompletingBuy;
    bytes buyWhilePendingError;
    uint128 basisCostBefore;
    uint128 basisTokensBefore;
    uint256 basisHighWaterBefore;
    uint256 tokensSold;
    uint256 usdcOut;
    uint64 soldCharged;
    uint8 phaseAfterSell;
    uint8 phaseAfterRetry;
    uint256 gasPendingBuy;
    uint256 gasPendingSell;
}

/// @dev Case 5: the owner blocklisted by the real USDC blocklister.
struct BlocklistResult {
    bool ownerBlocklisted;
    bytes ownerWithdrawNativeError;
    bytes ownerWithdrawUsdcError;
    bytes ownerWithdrawManyError;
    bytes agentSweepNativeError;
    bytes agentWithdrawError;
    bytes agentTransferOwnershipError;
    bytes agentSweepUsdcError;
    bool ownerWithdrawTokenOk;
    uint256 ownerTokensReceived;
    uint256 accountWeiBefore;
    uint256 accountWeiAfter;
    uint256 ownerWeiAfter;
    uint256 agentWeiAfter;
    uint256 gasBlockedWithdraw;
}

/// @dev Case 6: pool buy and sell through the Universal Router with Arc's real USDC approve and Permit2 allowance.
struct PoolSwapResult {
    uint256 buyOut;
    uint256 sellOut;
    uint256 usdcViewBefore;
    uint256 usdcViewAfterBuy;
    uint256 nativeBefore;
    uint256 nativeAfterBuy;
    uint64 spent;
    uint256 usdcAllowanceToPermit2;
    uint256 tokenAllowanceToPermit2;
    uint160 permit2UsdcLeft;
    uint160 permit2TokenLeft;
    uint256 gasBuy;
    uint256 gasSell;
}

/// @dev A caller the scenario creates: an account owner or an agent key. Only its creator can drive it; it measures
///      the gas of the call it forwards and returns the raw revert data on failure.
contract AgentLiveActor {
    address private immutable CREATOR;

    constructor() {
        CREATOR = msg.sender;
    }

    receive() external payable {}

    /// @dev Calls `target` with `data`; reports success, return or revert data and the call's gas.
    function exec(address target, bytes calldata data) external returns (bool ok, bytes memory ret, uint256 gasUsed) {
        require(msg.sender == CREATOR, "actor: not creator");
        uint256 g = gasleft();
        (ok, ret) = target.call(data);
        gasUsed = g - gasleft();
    }
}

/// @dev Spec section 10 fork cases that need Arc's native-coin precompiles. Not deployed anywhere: the test places
///      this runtime at an address through an `eth_call` state override at the pinned block, so the Arc testnet node
///      itself executes every step against the deployed agent factory and registry, Launch, Permit2, the Universal
///      Router, the PoolManager and the real USDC at 0x3600…0000 with its Native Coin Authority (0x1800…0000) and
///      Native Coin Control blocklist (0x1800…0001) precompiles, which a Foundry fork cannot run. Nothing persists:
///      `eth_call` state is discarded. Each scenario creates its own owner and agent contracts and account through
///      the deployed factory; its own address only acts as the whale that buys a curve up, and for the blocklist
///      scenarios it is the real USDC blocklister's address so `blacklist` passes Circle's role check. No storage,
///      no constructor: overridden code starts with empty storage.
contract AgentLiveScenario {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant SCALE = 1e12;

    /// @dev Takes the refund of the whale's completing buy in `poolSwap`.
    receive() external payable {}

    /// @dev Case 1. Buys `token`'s curve up until about `leaveWei` of buying is left, then the agent buys
    ///      `agentUsdc` (usdc6), more than is left, so the account's buy completes the curve and graduates it.
    function graduatingBuy(LiveAddrs calldata a, address token, uint256 leaveWei, uint256 agentUsdc)
        external
        returns (GraduationResult memory r)
    {
        (AgentAccount account,, AgentLiveActor agent) = _account(a, 2_000e18);
        BondingCurve curve = BondingCurve(payable(LaunchFactory(a.launchFactory).curveOf(token)));
        _fill(curve, leaveWei);
        r.remainingBefore = curve.curveSupply() - curve.sold();
        (, r.quotedUsedWei,,) = curve.quoteBuy(agentUsdc * SCALE);
        uint256 bal0 = address(account).balance;
        bytes memory ret;
        (ret, r.gas) =
            _do(agent, address(account), abi.encodeCall(AgentAccount.buy, (token, agentUsdc, 1, block.timestamp + 60)));
        r.tokensOut = abi.decode(ret, (uint256));
        r.deltaWei = bal0 - address(account).balance;
        r.phaseAfter = uint8(curve.phase());
        AgentPolicyRegistry registry = AgentPolicyRegistry(AgentAccountFactory(a.agentFactory).registry());
        (, r.spent,, r.actions,) = registry.usage(address(account));
        r.tokenSpent = registry.tokenSpent(address(account), token);
        (r.basisCost, r.basisTokens,) = account.basis(token);
        PoolKey memory key = GraduationManager(a.graduationManager).poolKey(token);
        (r.poolSqrtPriceX96,,,) = IPoolManager(a.poolManager).getSlot0(key.toId());
    }

    /// @dev Case 2. The agent holds a position, the curve is bought up, the real blocklister blocklists the
    ///      GraduationManager, and the agent's completing buy then leaves the curve `GraduationPending` (the curve
    ///      catches the failed graduation). A buy is refused, half the position is sold, and once the blocklisting is
    ///      lifted the next buy that completes the curve (the whale's) graduates it.
    function sellWhilePending(LiveAddrs calldata a, address token, uint256 leaveWei, uint256 agentUsdc)
        external
        returns (PendingResult memory r)
    {
        (AgentAccount account,, AgentLiveActor agent) = _account(a, 2_000e18);
        BondingCurve curve = BondingCurve(payable(LaunchFactory(a.launchFactory).curveOf(token)));
        _do(agent, address(account), abi.encodeCall(AgentAccount.buy, (token, 50e6, 1, block.timestamp + 60)));
        _fill(curve, leaveWei);

        IUsdcBlocklist(a.usdc).blacklist(a.graduationManager);
        require(IUsdcBlocklist(a.usdc).isBlacklisted(a.graduationManager), "scenario: not blocklisted");
        (, r.gasPendingBuy) =
            _do(agent, address(account), abi.encodeCall(AgentAccount.buy, (token, agentUsdc, 1, block.timestamp + 60)));
        r.phaseAfterCompletingBuy = uint8(curve.phase());

        (, r.buyWhilePendingError,) =
            agent.exec(address(account), abi.encodeCall(AgentAccount.buy, (token, 1e6, 1, block.timestamp + 60)));

        (r.basisCostBefore, r.basisTokensBefore, r.basisHighWaterBefore) = account.basis(token);
        r.tokensSold = r.basisTokensBefore / 2;
        AgentPolicyRegistry registry = AgentPolicyRegistry(AgentAccountFactory(a.agentFactory).registry());
        (,, uint64 sold0,,) = registry.usage(address(account));
        bytes memory ret;
        (ret, r.gasPendingSell) = _do(
            agent, address(account), abi.encodeCall(AgentAccount.sell, (token, r.tokensSold, 1, block.timestamp + 60))
        );
        r.usdcOut = abi.decode(ret, (uint256));
        (,, uint64 sold1,,) = registry.usage(address(account));
        r.soldCharged = sold1 - sold0;
        r.phaseAfterSell = uint8(curve.phase());

        // The sold-back tokens are priced at the top of the curve, so the whale completes it this time.
        IUsdcBlocklist(a.usdc).unBlacklist(a.graduationManager);
        (, uint256 usedAll,,) = curve.quoteBuy(type(uint128).max);
        curve.buy{value: usedAll}(1, address(0), block.timestamp);
        r.phaseAfterRetry = uint8(curve.phase());
    }

    /// @dev Case 5. The account holds native USDC and `token`; the real blocklister blocklists the owner. Every exit
    ///      the owner and the agent have is tried; the results are returned for the test to assert.
    function blocklistedOwner(LiveAddrs calldata a, address token) external returns (BlocklistResult memory r) {
        (AgentAccount account, AgentLiveActor owner, AgentLiveActor agent) = _account(a, 100e18);
        _do(agent, address(account), abi.encodeCall(AgentAccount.buy, (token, 10e6, 1, block.timestamp + 60)));
        uint256 tokens = IERC20(token).balanceOf(address(account));

        IUsdcBlocklist(a.usdc).blacklist(address(owner));
        r.ownerBlocklisted = IUsdcBlocklist(a.usdc).isBlacklisted(address(owner));
        r.accountWeiBefore = address(account).balance;

        uint256 g;
        (, r.ownerWithdrawNativeError, g) =
            owner.exec(address(account), abi.encodeCall(AgentAccount.withdraw, (address(0), 1e18)));
        r.gasBlockedWithdraw = g;
        (, r.ownerWithdrawUsdcError,) =
            owner.exec(address(account), abi.encodeCall(AgentAccount.withdraw, (a.usdc, 1e6)));
        address[] memory all = new address[](1);
        (, r.ownerWithdrawManyError,) = owner.exec(address(account), abi.encodeCall(AgentAccount.withdrawMany, (all)));
        (, r.agentSweepNativeError,) =
            agent.exec(address(account), abi.encodeCall(AgentAccount.sweepToOwner, (address(0), 1e18)));
        (, r.agentWithdrawError,) =
            agent.exec(address(account), abi.encodeCall(AgentAccount.withdraw, (address(0), 1e18)));
        address registry = AgentAccountFactory(a.agentFactory).registry();
        (, r.agentTransferOwnershipError,) = agent.exec(
            registry, abi.encodeCall(AgentPolicyRegistry.transferOwnership, (address(account), address(agent)))
        );
        (, r.agentSweepUsdcError,) =
            agent.exec(address(account), abi.encodeCall(AgentAccount.sweepToOwner, (a.usdc, 1e6)));
        r.accountWeiAfter = address(account).balance;

        // A Launch token is not USDC: the blocklist does not cover it, so this exit still works.
        uint256 ownerTokens0 = IERC20(token).balanceOf(address(owner));
        (r.ownerWithdrawTokenOk,,) =
            owner.exec(address(account), abi.encodeCall(AgentAccount.withdraw, (token, tokens)));
        r.ownerTokensReceived = IERC20(token).balanceOf(address(owner)) - ownerTokens0;
        r.ownerWeiAfter = address(owner).balance;
        r.agentWeiAfter = address(agent).balance;
    }

    /// @dev Case 6. Graduates `token`'s curve as in case 1, then the agent buys on the new pool with `buyUsdc` (usdc6)
    ///      and sells half of what it got, through the deployed Universal Router: Arc's real USDC `approve` to Permit2,
    ///      Permit2's allowance to the router and Permit2's `transferFrom` of the real USDC.
    function poolSwap(LiveAddrs calldata a, address token, uint256 leaveWei, uint256 buyUsdc)
        external
        returns (PoolSwapResult memory r)
    {
        (AgentAccount account,, AgentLiveActor agent) = _account(a, 2_000e18);
        BondingCurve curve = BondingCurve(payable(LaunchFactory(a.launchFactory).curveOf(token)));
        _fill(curve, leaveWei);
        curve.buy{value: leaveWei * 2}(1, address(0), block.timestamp);
        require(curve.phase() == BondingCurve.Phase.Graduated, "scenario: not graduated");

        r.usdcViewBefore = IERC20(a.usdc).balanceOf(address(account));
        r.nativeBefore = address(account).balance;
        bytes memory ret;
        (ret, r.gasBuy) = _do(
            agent,
            address(account),
            abi.encodeCall(AgentAccount.swapExactIn, (token, true, buyUsdc, 1, block.timestamp + 60))
        );
        r.buyOut = abi.decode(ret, (uint256));
        r.usdcViewAfterBuy = IERC20(a.usdc).balanceOf(address(account));
        r.nativeAfterBuy = address(account).balance;
        (, r.spent,,,) = AgentPolicyRegistry(AgentAccountFactory(a.agentFactory).registry()).usage(address(account));

        (ret, r.gasSell) = _do(
            agent,
            address(account),
            abi.encodeCall(AgentAccount.swapExactIn, (token, false, r.buyOut / 2, 1, block.timestamp + 60))
        );
        r.sellOut = abi.decode(ret, (uint256));

        r.usdcAllowanceToPermit2 = IERC20(a.usdc).allowance(address(account), a.permit2);
        r.tokenAllowanceToPermit2 = IERC20(token).allowance(address(account), a.permit2);
        address router = account.UNIVERSAL_ROUTER();
        (r.permit2UsdcLeft,,) = IAllowanceTransfer(a.permit2).allowance(address(account), a.usdc, router);
        (r.permit2TokenLeft,,) = IAllowanceTransfer(a.permit2).allowance(address(account), token, router);
    }

    /// @dev An owner contract creates an account through the deployed factory with the beta ceilings as its policy
    ///      and an agent contract as its first agent; the scenario funds it with `fundWei`.
    function _account(LiveAddrs calldata a, uint256 fundWei)
        private
        returns (AgentAccount account, AgentLiveActor owner, AgentLiveActor agent)
    {
        owner = new AgentLiveActor();
        agent = new AgentLiveActor();
        AgentAccountFactory factory = AgentAccountFactory(a.agentFactory);
        InitParams memory p;
        p.policy = factory.ceilings();
        p.policy.maxDeadlineSeconds = 120;
        p.periodSeconds = 1 days;
        p.increaseDelay = 1 hours;
        p.firstAgent = address(agent);
        p.firstAgentExpiresAt = uint40(block.timestamp + 30 days);
        p.firstAgentPermissions = P_ALL;
        (bytes memory ret,) =
            _do(owner, address(factory), abi.encodeCall(AgentAccountFactory.createAccount, (bytes32(0), p)));
        account = AgentAccount(payable(abi.decode(ret, (address))));
        (bool ok,) = address(account).call{value: fundWei}("");
        require(ok, "scenario: fund");
    }

    /// @dev Buys `curve` from this address until about `leaveWei` of gross buying is left before it completes.
    function _fill(BondingCurve curve, uint256 leaveWei) private {
        (, uint256 usedAll,,) = curve.quoteBuy(type(uint128).max);
        curve.buy{value: usedAll - leaveWei}(1, address(0), block.timestamp);
        require(curve.phase() == BondingCurve.Phase.Trading, "scenario: filled too far");
    }

    /// @dev Drives `actor` to call `target`; bubbles a failure's revert data.
    function _do(AgentLiveActor actor, address target, bytes memory data)
        private
        returns (bytes memory ret, uint256 gasUsed)
    {
        bool ok;
        (ok, ret, gasUsed) = actor.exec(target, data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
