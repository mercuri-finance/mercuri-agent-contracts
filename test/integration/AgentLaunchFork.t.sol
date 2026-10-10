// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {LaunchFactory} from "@mercuri/launch/LaunchFactory.sol";
import {FeeManager} from "@mercuri/launch/FeeManager.sol";
import {IFeeManager} from "@mercuri/launch/interfaces/IFeeManager.sol";
import {LaunchConfig} from "@mercuri/launch/libraries/LaunchTypes.sol";
import {AgentAccount} from "../../src/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/AgentAccountFactory.sol";
import {AgentPolicyRegistry} from "../../src/AgentPolicyRegistry.sol";
import {IAgentAccount} from "../../src/interfaces/IAgentAccount.sol";
import {IAgentPolicyRegistry} from "../../src/interfaces/IAgentPolicyRegistry.sol";
import {InitParams, LaunchRequest, P_ALL} from "../../src/libraries/AgentTypes.sol";
import {
    AgentLiveScenario,
    BlocklistResult,
    GraduationResult,
    IUsdcBlocklist,
    LiveAddrs,
    PendingResult,
    PoolSwapResult
} from "../utils/AgentLiveScenario.sol";

/// @dev Spec section 10 pinned-fork cases against the agent accounts deployed on Arc testnet
///      (`deployments/5042002.json`: the real factory, registry and implementation, never a fresh deployment) and the
///      deployed Launch contracts, at one pinned block. Read-only: nothing is broadcast. Skipped unless
///      ARC_LOCAL_FORK_RPC is set; the cases that need Arc's native-coin precompiles also skip unless that endpoint is
///      Arc's own node (the public `https://rpc.testnet.arc.io`, never a paid provider).
///
///      Two execution modes, both at `TESTNET_BLOCK`:
///      - Foundry fork (launch with an initial buy, creator fee claim): these paths move only native value, so the
///        fork runs them exactly as Arc does.
///      - Arc node `eth_call` (graduating buy, sell while `GraduationPending`, blocklisted owner, pool swap with the
///        real USDC). Arc's USDC at 0x3600…0000 is Circle's FiatToken proxy whose `transfer` and `transferFrom` call
///        the Native Coin Authority precompile (0x1800…0000) and whose blocklist lives in the Native Coin Control
///        precompile (0x1800…0001). Foundry's EVM has neither (the testnet code there is a one-byte placeholder), so
///        a fork reverts on every USDC transfer, graduation included, and cannot blocklist anyone. Rather than model
///        them, `AgentLiveScenario` runs on Arc's node through `eth_call` with two state overrides: its runtime code
///        at the scenario address and a USDC balance for the whale it plays. Everything else is the live state at
///        the pinned block, executed by Arc itself; the result is returned and asserted here, and nothing persists.
///        The blocklist cases put the scenario at the real USDC blocklister's address, so Circle's own role check in
///        `blacklist` passes: the eth_call form of impersonating the blocklister on a fork.
///
///      The curve these cases buy up is a real testnet launch in `Trading` at the pinned block, past its snipe window.
contract AgentLaunchForkTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    /// @dev A pinned testnet block after the agent factory's deployment (66,495,930).
    uint256 internal constant TESTNET_BLOCK = 66_497_000;
    /// @dev A testnet launch in `Trading` at that block, about 2% sold, launched at block 63,134,963.
    address internal constant TRADING_TOKEN = 0x93f8be7765084d155F3A33E0FA058f1Dcd6003F1;
    /// @dev USDC's `blacklister()` at the pinned block (an EOA).
    address internal constant USDC_BLOCKLISTER = 0x9338f53291715F1126291E28BBd3B9989e966572;
    /// @dev Arc's Native Coin Control precompile, which holds the USDC blocklist.
    address internal constant NATIVE_COIN_CONTROL = 0x1800000000000000000000000000000000000001;
    /// @dev An address on Arc testnet's seeded USDC blocklist (`isBlocklisted` is true at the pinned block).
    address internal constant SEED_BLOCKLISTED = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    /// @dev Neutral address the non-blocklist scenarios run at.
    address internal constant SCENARIO_HOST = address(uint160(uint256(keccak256("mercurifi agent live scenario"))));
    /// @dev Arc's per-transaction gas cap (EIP-7825), measured on testnet.
    uint256 internal constant TX_GAS_CAP = 16_777_216;
    /// @dev Gross buying left on the curve before the completing buy, as in the curve suite.
    uint256 internal constant LEAVE_WEI = 60e18 + 123_456_789;

    AgentAccountFactory internal agentFactory;
    AgentPolicyRegistry internal registry;
    LaunchFactory internal launchFactory;
    FeeManager internal feeManager;
    LiveAddrs internal live;
    address internal owner = makeAddr("account owner");
    address internal agentKey = makeAddr("agent key");
    address internal liveCaller = makeAddr("live caller");

    function setUp() public {
        string memory rpc = vm.envOr("ARC_LOCAL_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        // Tests never use a paid provider: refuse an Alchemy endpoint outright.
        require(!vm.contains(vm.toLowercase(rpc), "alchemy"), "fork tests must not use Alchemy");
        uint256 chain = vm.envOr("AGENT_FORK_CHAIN_ID", uint256(5042002));
        require(chain == 5042002 || chain == 5042, "unsupported fork chain");
        // The agent accounts are deployed on testnet only.
        if (chain != 5042002) vm.skip(true);
        vm.createSelectFork(rpc, vm.envOr("AGENT_FORK_BLOCK", TESTNET_BLOCK));
        assertEq(block.chainid, chain);

        // The deployed agent accounts, from their deployment record.
        string memory record = vm.readFile("deployments/5042002.json");
        agentFactory = AgentAccountFactory(vm.parseJsonAddress(record, ".factory"));
        registry = AgentPolicyRegistry(vm.parseJsonAddress(record, ".registry"));
        assertGe(block.number, vm.parseJsonUint(record, ".factoryDeployBlock"), "fork after the factory deployment");
        assertEq(agentFactory.registry(), address(registry), "deployed registry");
        assertEq(
            agentFactory.implementation(), vm.parseJsonAddress(record, ".implementation"), "deployed implementation"
        );
        assertGt(address(agentFactory).code.length, 0);
        launchFactory = LaunchFactory(vm.parseJsonAddress(record, ".launchFactory"));
        feeManager = FeeManager(vm.parseJsonAddress(record, ".feeManager"));
        live = LiveAddrs({
            agentFactory: address(agentFactory),
            launchFactory: address(launchFactory),
            feeManager: address(feeManager),
            graduationManager: vm.parseJsonAddress(record, ".graduationManager"),
            poolManager: vm.parseJsonAddress(record, ".poolManager"),
            permit2: vm.parseJsonAddress(record, ".permit2"),
            usdc: vm.parseJsonAddress(record, ".usdc")
        });
        assertEq(live.usdc, USDC);
    }

    // ---------------------------------------------------------------- Arc node (eth_call at the pinned block)

    /// An agent curve buy larger than what is left completes the curve; the curve graduates inside the same call
    /// (LaunchHook pool initialised), the account is charged only what the curve took (the refund netted, rounded up
    /// to usdc6) and its basis holds exactly the remaining supply. Run by Arc's node: graduation moves real USDC.
    function test_agentCurveBuyGraduatesTheCurve() public {
        _requireArcNode();
        GraduationResult memory r = abi.decode(
            _liveCall(
                SCENARIO_HOST, abi.encodeCall(AgentLiveScenario.graduatingBuy, (live, TRADING_TOKEN, LEAVE_WEI, 100e6))
            ),
            (GraduationResult)
        );
        emit log_named_uint("agent graduating curve buy gas (Arc node)", r.gas);
        assertEq(r.phaseAfter, uint8(BondingCurve.Phase.Graduated), "graduated in the agent's buy");
        assertGt(r.poolSqrtPriceX96, 0, "LaunchHook pool initialised");
        assertEq(r.tokensOut, r.remainingBefore, "bought exactly what was left");
        assertLt(r.quotedUsedWei, 100e18, "a refund was due");
        assertEq(r.deltaWei, r.quotedUsedWei, "refund netted");
        uint256 spent6 = Math.ceilDiv(r.deltaWei, 1e12);
        assertEq(r.spent, spent6, "spend charged in usdc6, rounded up");
        assertEq(r.tokenSpent, spent6, "per-token spend");
        assertEq(r.actions, 1);
        assertEq(r.basisCost, spent6, "basis cost");
        assertEq(r.basisTokens, r.tokensOut, "basis tokens");
        assertLt(r.gas, TX_GAS_CAP, "fits Arc's per-transaction gas cap");
    }

    /// The real USDC blocklister blocklists the GraduationManager, so the agent's completing buy leaves the curve
    /// `GraduationPending` (Launch catches the failed graduation). The agent's buy is then refused `NotTrading`, its
    /// sell succeeds, is charged its recorded cost-basis value and reopens `Trading`; once the blocklisting is lifted
    /// the next buy that completes the curve graduates it. Blocklisting a Launch contract is the only route to
    /// `GraduationPending` on the live system that needs no Launch fault; it needs Arc's node (see the contract
    /// NatSpec).
    function test_agentSellWhileGraduationPending() public {
        _requireArcNode();
        PendingResult memory r = abi.decode(
            _liveCall(
                USDC_BLOCKLISTER,
                abi.encodeCall(AgentLiveScenario.sellWhilePending, (live, TRADING_TOKEN, LEAVE_WEI, 100e6))
            ),
            (PendingResult)
        );
        emit log_named_uint("agent completing buy, graduation deferred, gas (Arc node)", r.gasPendingBuy);
        emit log_named_uint("agent curve sell while GraduationPending gas (Arc node)", r.gasPendingSell);
        assertEq(r.phaseAfterCompletingBuy, uint8(BondingCurve.Phase.GraduationPending), "graduation deferred");
        assertEq(r.buyWhilePendingError, abi.encodeWithSelector(IAgentAccount.NotTrading.selector), "buy refused");
        assertGt(r.usdcOut, 0, "sell paid native USDC");
        uint256 expected = Math.max(
            Math.mulDiv(r.tokensSold, r.basisCostBefore, r.basisTokensBefore, Math.Rounding.Ceil),
            Math.mulDiv(r.tokensSold, r.basisHighWaterBefore, 1e36)
        );
        assertEq(r.soldCharged, expected, "the pending-phase sell is charged its basis value");
        assertEq(r.phaseAfterSell, uint8(BondingCurve.Phase.Trading), "the sell reopens trading");
        assertEq(r.phaseAfterRetry, uint8(BondingCurve.Phase.Graduated), "graduates once unblocked");
    }

    /// The real USDC blocklister blocklists the account's owner. Every native and USDC exit reverts: the owner's
    /// `withdraw` and `withdrawMany` and the agent's `sweepToOwner` fail at Arc's blocklist (`NativeTransferFailed`,
    /// or USDC's own `Blocked address`); the agent cannot withdraw, take ownership or sweep USDC through its ERC-20
    /// view; the account's balance is untouched and nobody else received anything. Launch tokens are not USDC and
    /// still withdraw. An EOA owner on the blocklist cannot even submit the call: Arc's node refuses it.
    function test_blocklistedOwnerCannotWithdraw() public {
        _requireArcNode();
        // On a Foundry fork the blocklister's own call reverts: the blocklist precompile does not exist there.
        vm.prank(USDC_BLOCKLISTER);
        vm.expectRevert();
        IUsdcBlocklist(USDC).blacklist{gas: 1_000_000}(owner);

        BlocklistResult memory r = abi.decode(
            _liveCall(USDC_BLOCKLISTER, abi.encodeCall(AgentLiveScenario.blocklistedOwner, (live, TRADING_TOKEN))),
            (BlocklistResult)
        );
        emit log_named_uint("blocklisted owner withdraw, reverted, gas (Arc node)", r.gasBlockedWithdraw);
        assertTrue(r.ownerBlocklisted, "owner blocklisted by the real blocklister");
        bytes memory nativeFailed = abi.encodeWithSelector(IAgentAccount.NativeTransferFailed.selector);
        assertEq(r.ownerWithdrawNativeError, nativeFailed, "native withdraw reverts");
        assertEq(r.ownerWithdrawUsdcError, abi.encodeWithSignature("Error(string)", "Blocked address"), "USDC view");
        assertEq(r.ownerWithdrawManyError, nativeFailed, "withdrawMany reverts");
        assertEq(r.agentSweepNativeError, nativeFailed, "the agent's sweep goes only to the owner, and reverts");
        assertEq(r.agentWithdrawError, abi.encodeWithSelector(IAgentAccount.NotOwner.selector), "agent withdraw");
        assertEq(
            r.agentTransferOwnershipError,
            abi.encodeWithSelector(IAgentPolicyRegistry.NotOwner.selector),
            "agent cannot take ownership"
        );
        assertEq(
            r.agentSweepUsdcError,
            abi.encodeWithSelector(IAgentAccount.TokenNotRegistered.selector),
            "agent cannot sweep through USDC's ERC-20 view"
        );
        assertGt(r.accountWeiBefore, 0);
        assertEq(r.accountWeiAfter, r.accountWeiBefore, "funds stay in the account");
        assertEq(r.ownerWeiAfter, 0, "owner received nothing");
        assertEq(r.agentWeiAfter, 0, "agent received nothing");
        assertTrue(r.ownerWithdrawTokenOk, "Launch tokens are outside the USDC blocklist");
        assertGt(r.ownerTokensReceived, 0);

        // A blocklisted EOA owner: Arc's node refuses the call before it runs.
        string memory params = string.concat(
            '[{"from":"',
            vm.toString(SEED_BLOCKLISTED),
            '","to":"',
            vm.toString(agentFactory.implementation()),
            '","data":"',
            vm.toString(abi.encodeCall(AgentAccount.withdraw, (address(0), 1))),
            '"},"',
            _quantity(TESTNET_BLOCK),
            '"]'
        );
        try vm.rpc("eth_call", params) {
            fail("a blocklisted sender's call was accepted");
        } catch (bytes memory err) {
            assertTrue(vm.contains(string(err), "Blocked address"), string(err));
        }
    }

    /// After a graduation, the agent buys and sells on the LaunchHook pool through the deployed Universal Router with
    /// Arc's real USDC: the account's ERC-20 `approve` to Permit2, Permit2's allowance to the router and Permit2's
    /// `transferFrom` of USDC all run on the real token. USDC's 6-decimal ERC-20 balance equals the native balance
    /// scaled, the spend is the native delta, and every allowance is back to zero after both trades.
    function test_agentPoolSwapWithRealUsdcApproveAndPermit2() public {
        _requireArcNode();
        PoolSwapResult memory r = abi.decode(
            _liveCall(
                SCENARIO_HOST, abi.encodeCall(AgentLiveScenario.poolSwap, (live, TRADING_TOKEN, LEAVE_WEI, 10e6))
            ),
            (PoolSwapResult)
        );
        emit log_named_uint("agent pool buy gas, real USDC and Permit2 (Arc node)", r.gasBuy);
        emit log_named_uint("agent pool sell gas, real USDC and Permit2 (Arc node)", r.gasSell);
        assertGt(r.buyOut, 0, "pool buy delivered tokens");
        assertGt(r.sellOut, 0, "pool sell paid USDC");
        assertEq(r.usdcViewBefore, r.nativeBefore / 1e12, "one balance, two views");
        assertEq(r.usdcViewAfterBuy, r.nativeAfterBuy / 1e12, "one balance, two views after the buy");
        assertEq(r.spent, Math.ceilDiv(r.nativeBefore - r.nativeAfterBuy, 1e12), "spend is the native delta");
        assertLe(r.spent, 10e6);
        assertEq(r.usdcAllowanceToPermit2, 0, "USDC allowance to Permit2 back to zero");
        assertEq(r.tokenAllowanceToPermit2, 0, "token allowance to Permit2 back to zero");
        assertEq(r.permit2UsdcLeft, 0, "Permit2 USDC allowance to the router spent");
        assertEq(r.permit2TokenLeft, 0, "Permit2 token allowance to the router spent");
    }

    // ---------------------------------------------------------------- Foundry fork

    /// The agent launches with an initial buy through the deployed Launch factory. The account is the creator at the
    /// FeeManager; the referrer it bound at creation (before any trade) is the one paid on the initial buy's fee;
    /// launching locks the binding. An account created without a referrer leaves the referral share with the
    /// platform for good, and a referrer equal to the account's own predicted address is refused at creation.
    function test_agentLaunchWithInitialBuy() public {
        address referrer = makeAddr("integrator referrer");
        address predicted = agentFactory.predictAccount(owner, bytes32(uint256(1)));
        vm.expectEmit(true, true, false, false, address(feeManager));
        emit IFeeManager.ReferralBound(predicted, referrer);
        AgentAccount account = _createAccount(bytes32(uint256(1)), referrer);
        assertEq(address(account), predicted);
        assertEq(feeManager.referrerOf(address(account)), referrer, "bound at creation");
        assertFalse(feeManager.hasTraded(address(account)));

        LaunchConfig memory cfg = launchFactory.config();
        uint256 referrerOwed0 = feeManager.balances(referrer);
        uint256 bal0 = address(account).balance;
        LaunchRequest memory req = _launchRequest("Agent Fork Launch", "AGFL", 50e6);
        vm.prank(agentKey);
        uint256 g = gasleft();
        (address token, address curve) = account.launch(req);
        emit log_named_uint("agent launch with a 50 USDC initial buy gas (deployed Launch factory)", g - gasleft());

        assertEq(launchFactory.curveOf(token), curve, "registered launch");
        IFeeManager.TokenInfo memory info = feeManager.tokenInfo(token);
        assertEq(info.creator, address(account), "creator is the account");
        assertEq(info.curve, curve);
        assertEq(BondingCurve(payable(curve)).launchBlock(), block.number);
        assertEq(feeManager.referrerOf(address(account)), referrer, "binding unchanged by the launch");
        assertTrue(feeManager.hasTraded(address(account)), "the initial buy is the account's first trade");
        uint256 fee = 50e18 * uint256(cfg.tradeFeeBps) / 10_000;
        assertEq(
            feeManager.balances(referrer) - referrerOwed0, fee * uint256(cfg.referrerShareBps) / 10_000, "referrer paid"
        );
        assertEq(
            feeManager.balances(address(account)),
            fee * uint256(cfg.creatorShareBps) / 10_000,
            "creator share to account"
        );

        uint256 tokens = IERC20(token).balanceOf(address(account));
        assertGt(tokens, 0, "initial buy tokens in the account");
        uint256 spentWei = bal0 - address(account).balance;
        assertEq(spentWei, cfg.launchFee + 50e18, "launch fee plus initial buy");
        (, uint64 spent,, uint32 actions, uint16 launches) = registry.usage(address(account));
        assertEq(spent, spentWei / 1e12);
        assertEq(actions, 1);
        assertEq(launches, 1);
        (uint128 cost, uint128 held,) = account.basis(token);
        assertEq(held, tokens);
        assertEq(cost, spent - Math.ceilDiv(cfg.launchFee, 1e12), "basis excludes the launch fee");

        // No referrer: the launch passes none, nothing binds, and the trade locks the binding for good.
        AgentAccount plain = _createAccount(bytes32(uint256(2)), address(0));
        req = _launchRequest("Agent Fork Plain", "AGFP", 5e6);
        vm.prank(agentKey);
        plain.launch(req);
        assertEq(feeManager.referrerOf(address(plain)), address(0), "platform keeps the referral share");
        vm.prank(address(plain));
        vm.expectRevert(IFeeManager.ReferrerLocked.selector);
        feeManager.bindReferrer(referrer);

        // A referrer equal to the account's own address is refused before anything is created.
        address self = agentFactory.predictAccount(owner, bytes32(uint256(3)));
        InitParams memory p = _init(self);
        vm.prank(owner);
        vm.expectRevert(IAgentAccount.SelfReferrer.selector);
        agentFactory.createAccount(bytes32(uint256(3)), p);
    }

    /// Creator fees from other traders' curve trades on the account's launch are claimed by the agent into the account
    /// itself (`FeeManager.claim(address(this))`): the account's native balance rises by exactly what the FeeManager
    /// owed it, the FeeManager owes it nothing after, and neither the owner nor the agent receives anything.
    function test_agentClaimsCreatorFeesIntoTheAccount() public {
        AgentAccount account = _createAccount(bytes32(uint256(4)), address(0));
        LaunchRequest memory req = _launchRequest("Agent Fork Fees", "AGFF", 10e6);
        vm.prank(agentKey);
        (address token, address curve) = account.launch(req);
        // Past the snipe window, another wallet trades the account's launch.
        vm.roll(block.number + launchFactory.config().snipeBlocks + 1);
        address trader = makeAddr("curve trader");
        vm.deal(trader, 1_000e18);
        vm.startPrank(trader);
        uint256 bought = BondingCurve(payable(curve)).buy{value: 500e18}(1, address(0), block.timestamp);
        IERC20(token).approve(curve, bought / 2);
        BondingCurve(payable(curve)).sell(bought / 2, 1, address(0), block.timestamp);
        vm.stopPrank();

        uint256 owed = feeManager.balances(address(account));
        assertGt(owed, 0, "creator fees owed to the account");
        uint256 bal0 = address(account).balance;
        uint256 ownerBal0 = owner.balance;
        uint256 agentBal0 = agentKey.balance;
        vm.expectEmit(true, true, false, true, address(feeManager));
        emit IFeeManager.FeeClaimed(address(account), address(account), owed);
        vm.prank(agentKey);
        uint256 g = gasleft();
        uint256 claimed = account.claimFees();
        emit log_named_uint("agent creator fee claim gas (deployed FeeManager)", g - gasleft());
        assertEq(claimed, owed / 1e12, "claimed in usdc6, rounded down");
        assertEq(address(account).balance - bal0, owed, "the whole claim lands in the account");
        assertEq(feeManager.balances(address(account)), 0, "nothing left owed");
        assertEq(owner.balance, ownerBal0, "owner received nothing");
        assertEq(agentKey.balance, agentBal0, "agent received nothing");
        (,,, uint32 actions,) = registry.usage(address(account));
        assertEq(actions, 2, "the claim counts as an action");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Creates an account through the deployed factory for `owner`, with the beta ceilings and the agent key.
    function _createAccount(bytes32 salt, address referrer) internal returns (AgentAccount account) {
        InitParams memory p = _init(referrer);
        vm.prank(owner);
        account = AgentAccount(payable(agentFactory.createAccount(salt, p)));
        vm.deal(address(account), 2_000e18);
    }

    function _init(address referrer) internal view returns (InitParams memory p) {
        p.referrer = referrer;
        p.policy = agentFactory.ceilings();
        p.policy.maxDeadlineSeconds = 120;
        p.periodSeconds = 1 days;
        p.increaseDelay = 1 hours;
        p.firstAgent = agentKey;
        p.firstAgentExpiresAt = uint40(block.timestamp + 30 days);
        p.firstAgentPermissions = P_ALL;
    }

    function _launchRequest(string memory name, string memory symbol, uint256 initialBuyUsdc)
        internal
        view
        returns (LaunchRequest memory r)
    {
        r.name = name;
        r.symbol = symbol;
        r.metadataURI = "ipfs://agent-fork-test";
        r.salt = keccak256(bytes(name));
        r.expectedConfigHash = launchFactory.configHash();
        r.initialBuyUsdc = initialBuyUsdc;
        r.minTokensOut = 1;
        r.deadline = block.timestamp + 60;
    }

    /// @dev Skips unless the fork endpoint is Arc's own node: Arc's blocklist precompile answers, and reports the seed
    ///      address blocklisted. A loopback Anvil fork has no Arc precompiles.
    function _requireArcNode() internal {
        string memory params = string.concat(
            '[{"to":"',
            vm.toString(NATIVE_COIN_CONTROL),
            '","data":"',
            vm.toString(abi.encodeWithSignature("isBlocklisted(address)", SEED_BLOCKLISTED)),
            '"},"',
            _quantity(TESTNET_BLOCK),
            '"]'
        );
        try vm.rpc("eth_call", params) returns (bytes memory ret) {
            if (ret.length != 32 || abi.decode(ret, (uint256)) != 1) vm.skip(true);
        } catch {
            vm.skip(true);
        }
    }

    /// @dev `eth_call` on the fork endpoint at `TESTNET_BLOCK`, with `AgentLiveScenario`'s runtime and a 1,000,000 USDC
    ///      balance overridden at `host`. Reverts with the node's error if the call reverts.
    function _liveCall(address host, bytes memory data) internal returns (bytes memory) {
        string memory h = vm.toString(host);
        string memory params = string.concat(
            '[{"from":"',
            vm.toString(liveCaller),
            '","to":"',
            h,
            '","gas":"0x1c9c380","data":"',
            vm.toString(data),
            '"},"',
            _quantity(TESTNET_BLOCK),
            '",{"',
            h,
            '":{"code":"',
            vm.toString(type(AgentLiveScenario).runtimeCode),
            '","balance":"',
            _quantity(1_000_000e18),
            '"}}]'
        );
        return vm.rpc("eth_call", params);
    }

    /// @dev A JSON-RPC quantity: lowercase hex without leading zeros.
    function _quantity(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0x0";
        bytes memory digits = "0123456789abcdef";
        uint256 len;
        for (uint256 x = v; x != 0; x >>= 4) {
            ++len;
        }
        bytes memory out = new bytes(len + 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = len + 1; i > 1; --i) {
            out[i] = digits[v & 0xf];
            v >>= 4;
        }
        return string(out);
    }
}
