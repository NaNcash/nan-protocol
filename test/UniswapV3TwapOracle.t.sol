// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TwapOracle, IUniswapV3PoolTwap} from "../src/UniswapV3TwapOracle.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockERC20Decimals} from "./mocks/MockERC20.sol";
import {MockWstETH, MockAggregator} from "./mocks/MockChainlink.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";

contract TwapConsultHarness is UniswapV3TwapOracle {
    constructor(UniswapV3TwapOracle config)
        UniswapV3TwapOracle(
            config.wstETH(),
            config.weth(),
            config.usdc(),
            config.factory(),
            config.wstEthWethPool(),
            config.wethUsdcPool(),
            config.twapWindow(),
            config.minWstEthWethLiquidity(),
            config.minWethUsdcLiquidity()
        )
    {}

    function consult(IUniswapV3PoolTwap pool, uint128 minimumLiquidity) external view returns (int24) {
        return _consult(pool, minimumLiquidity);
    }
}

contract UniswapV3TwapOracleTest is Test {
    address internal constant WSTETH = address(0x100);
    address internal constant USDC = address(0x150);
    address internal constant WETH = address(0x200);
    uint128 internal constant LIQUIDITY = 1e18;
    uint128 internal constant MIN_LIQUIDITY = 1e17;
    uint32 internal constant WINDOW = 1 hours;

    MockUniswapV3Factory internal factory;
    MockUniswapV3Pool internal wstEthWethPool;
    MockUniswapV3Pool internal wethUsdcPool;
    UniswapV3TwapOracle internal twap;

    function setUp() public {
        MockERC20Decimals wstETH = new MockERC20Decimals("wstETH", "wstETH", 18);
        MockERC20Decimals weth = new MockERC20Decimals("WETH", "WETH", 18);
        MockERC20Decimals usdc = new MockERC20Decimals("USDC", "USDC", 6);
        vm.etch(WSTETH, address(wstETH).code);
        vm.etch(WETH, address(weth).code);
        vm.etch(USDC, address(usdc).code);

        factory = new MockUniswapV3Factory();
        wstEthWethPool = new MockUniswapV3Pool(address(factory), WSTETH, WETH, 100, 1_823, LIQUIDITY);
        wethUsdcPool = new MockUniswapV3Pool(address(factory), USDC, WETH, 500, 196_260, LIQUIDITY);
        factory.setPool(WSTETH, WETH, 100, address(wstEthWethPool));
        factory.setPool(USDC, WETH, 500, address(wethUsdcPool));

        twap = new UniswapV3TwapOracle(
            WSTETH, WETH, USDC, factory, wstEthWethPool, wethUsdcPool, WINDOW, MIN_LIQUIDITY, MIN_LIQUIDITY
        );
    }

    function testQuotesWstEthUsdAcrossBothTwapLegs() public view {
        assertApproxEqRel(twap.price(), 3_600e18, 5e15);
    }

    function _mockObservation(int56 tick0, int56 tick1, uint160 liquidity0, uint160 liquidity1) internal {
        int56[] memory ticks = new int56[](2);
        ticks[0] = tick0;
        ticks[1] = tick1;
        uint160[] memory liquidity = new uint160[](2);
        liquidity[0] = liquidity0;
        liquidity[1] = liquidity1;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = WINDOW;
        vm.mockCall(
            address(wstEthWethPool),
            abi.encodeCall(IUniswapV3PoolTwap.observe, (secondsAgos)),
            abi.encode(ticks, liquidity)
        );
    }

    function _liquidityDelta() internal pure returns (uint160) {
        return uint160(uint256(WINDOW) * (1 << 128) / LIQUIDITY);
    }

    function testTickAccumulatorPositiveWrapPreservesQuote() public {
        uint256 expected = twap.price();
        int56 first = type(int56).max - 10;
        int56 last;
        unchecked {
            last = first + int56(1_823 * int256(uint256(WINDOW)));
        }
        _mockObservation(first, last, 0, _liquidityDelta());
        assertEq(twap.price(), expected);
    }

    function testTickAccumulatorNegativeWrapRoundsMeanDown() public {
        wstEthWethPool.setMeanTick(-2);
        uint256 expected = twap.price();
        int56 first = type(int56).min + 10;
        int56 last;
        unchecked {
            last = first - int56(uint56(WINDOW)) - 1;
        }
        _mockObservation(first, last, 0, _liquidityDelta());
        assertEq(twap.price(), expected);
    }

    function testLiquidityAccumulatorWrapPreservesQuote() public {
        uint256 expected = twap.price();
        uint160 first = type(uint160).max - 10;
        uint160 last;
        unchecked {
            last = first + _liquidityDelta();
        }
        _mockObservation(0, int56(1_823 * int256(uint256(WINDOW))), first, last);
        assertEq(twap.price(), expected);
    }

    function testNegativeMeanTickRoundsDownWithoutWrap() public {
        wstEthWethPool.setMeanTick(-2);
        uint256 expected = twap.price();
        _mockObservation(0, -int56(uint56(WINDOW)) - 1, 0, _liquidityDelta());
        assertEq(twap.price(), expected);
    }

    function testFuzzAccumulatorOffsetsDoNotChangeMeanTick(
        int56 tick0,
        uint160 liquidity0,
        int24 rawTick,
        uint16 rawRemainder
    ) public {
        int24 mean = int24(bound(int256(rawTick), -887_271, 887_271));
        int56 delta = int56(mean) * int56(uint56(WINDOW)) + int56(uint56(uint256(rawRemainder) % WINDOW));
        int56 tick1;
        uint160 liquidity1;
        unchecked {
            tick1 = tick0 + delta;
            liquidity1 = liquidity0 + _liquidityDelta();
        }
        TwapConsultHarness harness = new TwapConsultHarness(twap);
        _mockObservation(tick0, tick1, liquidity0, liquidity1);
        assertEq(harness.consult(wstEthWethPool, MIN_LIQUIDITY), mean);
    }

    function testRejectsZeroLiquidityDelta() public {
        _mockObservation(0, 0, 123, 123);
        vm.expectRevert(UniswapV3TwapOracle.InvalidObservation.selector);
        twap.price();
    }

    function testRejectsImpossibleHarmonicLiquidity() public {
        _mockObservation(0, 0, 0, 1);
        vm.expectRevert(UniswapV3TwapOracle.InvalidObservation.selector);
        twap.price();
    }

    function testMaximumHistoricalLiquidityRemainsValid() public {
        // A floored observation at uint128.max liquidity can produce a harmonic
        // estimate of 2**128; it must not be rejected as an accumulator error.
        _mockObservation(0, 0, 0, WINDOW);
        TwapConsultHarness harness = new TwapConsultHarness(twap);
        assertEq(harness.consult(wstEthWethPool, MIN_LIQUIDITY), 0);
    }

    function testRejectsOutOfRangeMeanTick() public {
        _mockObservation(0, int56(887_273 * int256(uint256(WINDOW))), 0, _liquidityDelta());
        vm.expectRevert(UniswapV3TwapOracle.InvalidObservation.selector);
        twap.price();
    }

    function testWrappedHistoricalLiquidityStillEnforcesThreshold() public {
        uint160 first = type(uint160).max - 10;
        uint160 last;
        unchecked {
            last = first + uint160(uint256(WINDOW) * (1 << 128) / (MIN_LIQUIDITY / 2));
        }
        _mockObservation(0, 0, first, last);
        vm.expectRevert(UniswapV3TwapOracle.InsufficientLiquidity.selector);
        twap.price();
    }

    function testMalformedLengthsFailBeforeIndexing() public {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = WINDOW;
        for (uint256 i; i < 4; ++i) {
            int56[] memory ticks = new int56[](i == 0 ? 0 : i == 1 ? 3 : 2);
            uint160[] memory liquidity = new uint160[](i == 2 ? 0 : i == 3 ? 3 : 2);
            vm.mockCall(
                address(wstEthWethPool),
                abi.encodeCall(IUniswapV3PoolTwap.observe, (secondsAgos)),
                abi.encode(ticks, liquidity)
            );
            vm.expectRevert(UniswapV3TwapOracle.InvalidObservation.selector);
            twap.price();
        }
    }

    function testRejectsInsufficientHistoricalLiquidity() public {
        wstEthWethPool.setLiquidity(MIN_LIQUIDITY / 2, LIQUIDITY);
        vm.expectRevert(UniswapV3TwapOracle.InsufficientLiquidity.selector);
        twap.price();
    }

    function testRejectsInsufficientCurrentLiquidity() public {
        wethUsdcPool.setLiquidity(LIQUIDITY, MIN_LIQUIDITY / 2);
        vm.expectRevert(UniswapV3TwapOracle.InsufficientLiquidity.selector);
        twap.price();
    }

    function testRejectsMissingObservationHistory() public {
        wethUsdcPool.setAvailableHistory(WINDOW - 1);
        vm.expectRevert(MockUniswapV3Pool.NotEnoughHistory.selector);
        twap.price();
    }

    function testRejectsMalformedObservations() public {
        wstEthWethPool.setMalformedObservation(true);
        vm.expectRevert(UniswapV3TwapOracle.InvalidObservation.selector);
        twap.price();
    }

    function testRejectsUnavailablePool() public {
        wstEthWethPool.setUnavailable(true);
        vm.expectRevert(MockUniswapV3Pool.PoolUnavailable.selector);
        twap.price();
    }

    function testRejectsWrongPoolOrWindow() public {
        vm.expectRevert(UniswapV3TwapOracle.InvalidConfiguration.selector);
        new UniswapV3TwapOracle(
            WSTETH, WETH, USDC, factory, wstEthWethPool, wethUsdcPool, 15 minutes, MIN_LIQUIDITY, MIN_LIQUIDITY
        );

        factory.setPool(WSTETH, WETH, 100, address(0));
        vm.expectRevert(UniswapV3TwapOracle.InvalidPool.selector);
        new UniswapV3TwapOracle(
            WSTETH, WETH, USDC, factory, wstEthWethPool, wethUsdcPool, WINDOW, MIN_LIQUIDITY, MIN_LIQUIDITY
        );
    }

    function testRouterUsesTwapOnlyWhenPrimaryFails() public {
        vm.warp(10 days);
        MockWstETH accountingRate = new MockWstETH(1.2e18);
        MockAggregator primaryFeed = new MockAggregator(8, 3_000e8, block.timestamp);
        WstEthUsdOracle router = new WstEthUsdOracle(
            IWstETH(address(accountingRate)), IAggregatorV3(address(primaryFeed)), twap, 1 hours, 200
        );

        (uint256 normalPrice, bool normalFallback) = router.redemptionPrice();
        assertEq(normalPrice, 3_600e18);
        assertFalse(normalFallback);

        primaryFeed.setUnavailable(true);
        (uint256 degradedPrice, bool degradedFallback) = router.redemptionPrice();
        assertApproxEqRel(degradedPrice, 3_672e18, 5e15);
        assertTrue(degradedFallback);

        wethUsdcPool.setLiquidity(0, 0);
        vm.expectRevert(WstEthUsdOracle.FallbackUnavailable.selector);
        router.redemptionPrice();
    }
}
