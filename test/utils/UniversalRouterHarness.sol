// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LaunchFixture} from "./LaunchFixture.sol";
import {LaunchToken} from "@mercuri/launch/LaunchToken.sol";
import {BondingCurve} from "@mercuri/launch/BondingCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @dev The minimal Universal Router surface the agent tests call.
interface ICanonicalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @dev The pinned upstream Universal Router (built by `script/build-universal-router.sh`), a V4Quoter and
///      Launch/listed markets on top of the Launch fixture. Extracted unchanged from the order tests this suite was
///      developed beside.
abstract contract UniversalRouterHarness is LaunchFixture {
    ICanonicalRouter internal router;
    IV4Quoter internal quoter;
    address internal trader = makeAddr("router trader");
    address internal appRecipient = makeAddr("app fee recipient");
    /// The pool of each token's latest market.
    mapping(address token => PoolKey) internal marketKey;

    struct RouterParameters {
        address permit2;
        address weth9;
        address v2Factory;
        address v3Factory;
        bytes32 pairInitCodeHash;
        bytes32 poolInitCodeHash;
        address v4PoolManager;
        address v3NFTPositionManager;
        address v4PositionManager;
        address spokePool;
    }

    struct Market {
        LaunchToken token;
        PoolKey key;
        bool usdcIs0;
    }

    function setUp() public virtual {
        _deploySystem();
        _configureRouter();
        vm.deal(trader, 100_000e18);
        vm.deal(address(this), 100_000e18);
    }

    function _configureRouter() internal virtual {
        RouterParameters memory params;
        params.permit2 = address(permit2);
        params.v4PoolManager = address(poolManager);
        params.v4PositionManager = address(posm);
        router = ICanonicalRouter(
            deployCode("out/universal-router/UniversalRouter.sol/UniversalRouter.json", abi.encode(params))
        );
        quoter = new V4Quoter(poolManager);
    }

    function _market(bool below, bool mercuri) internal returns (Market memory m) {
        BondingCurve curve;
        (m.token, curve) = _createOrdered(below);
        _graduate(curve);
        m.key = _key(address(m.token));
        m.usdcIs0 = Currency.unwrap(m.key.currency0) == USDC;
        vm.prank(bob);
        m.token.transfer(trader, 10_000_000e18);
        if (!mercuri) {
            m.key.hooks = IHooks(address(0));
            m.key.fee = 3000;
            m.key.tickSpacing = 60;
            poolManager.initialize(m.key, uint160(1 << 96));
            PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(poolManager);
            vm.prank(bob);
            m.token.transfer(address(this), 1e18);
            m.token.approve(address(lp), type(uint256).max);
            IERC20(USDC).approve(address(lp), type(uint256).max);
            lp.modifyLiquidity(m.key, ModifyLiquidityParams(-887220, 887220, 1e9, bytes32(0)), "");
        }
        vm.startPrank(trader);
        m.token.approve(address(permit2), type(uint256).max);
        IERC20(USDC).approve(address(permit2), type(uint256).max);
        permit2.approve(address(m.token), address(router), type(uint160).max, type(uint48).max);
        permit2.approve(USDC, address(router), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        marketKey[address(m.token)] = m.key;
    }

    function _quote(Market memory m, bool buy, uint128 amount, bytes memory hookData) internal returns (uint256 out) {
        (out,) =
            quoter.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(m.key, buy == m.usdcIs0, amount, hookData));
    }

    function _swapInput(
        Market memory m,
        bool buy,
        uint128 amount,
        uint128 minimum,
        bytes memory hookData,
        bool toRouter
    ) internal pure returns (bytes memory) {
        Currency input = buy ? Currency.wrap(USDC) : Currency.wrap(address(m.token));
        Currency output = buy ? Currency.wrap(address(m.token)) : Currency.wrap(USDC);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(m.key, buy == m.usdcIs0, amount, minimum, 0, hookData));
        params[1] = abi.encode(input, uint256(amount));
        // TAKE maps address(2) to the router; TAKE_ALL always pays the initiating trader.
        params[2] = toRouter ? abi.encode(output, address(2), uint256(0)) : abi.encode(output, uint256(minimum));
        return abi.encode(
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                toRouter ? uint8(Actions.TAKE) : uint8(Actions.TAKE_ALL)
            ),
            params
        );
    }

    function _recipe(Market memory m, bool buy, uint128 amount, uint128 minimum, bytes memory hookData)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bool appFee = address(m.key.hooks) != address(hook);
        if (!appFee) {
            commands = hex"10";
            inputs = new bytes[](1);
            inputs[0] = _swapInput(m, buy, amount, minimum, hookData, false);
        } else if (buy) {
            uint128 fee = amount * 50 / 10_000;
            commands = hex"0210";
            inputs = new bytes[](2);
            inputs[0] = abi.encode(USDC, appRecipient, uint160(fee));
            inputs[1] = _swapInput(m, buy, amount - fee, minimum, "", false);
        } else {
            commands = hex"100604";
            inputs = new bytes[](3);
            inputs[0] = _swapInput(m, buy, amount, 0, "", true);
            inputs[1] = abi.encode(USDC, appRecipient, uint256(50));
            // The user's minimum is on net proceeds, after the app fee.
            inputs[2] = abi.encode(USDC, trader, uint256(minimum));
        }
    }

    function _execute(Market memory m, bool buy, uint128 amount, uint128 minimum, bytes memory hookData) internal {
        (bytes memory commands, bytes[] memory inputs) = _recipe(m, buy, amount, minimum, hookData);
        vm.prank(trader);
        router.execute(commands, inputs, block.timestamp + 60);
    }

    function _assertEmpty(Market memory m) internal view {
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(m.token.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }
}
