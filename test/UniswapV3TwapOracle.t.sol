// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TwapOracle} from "../src/UniswapV3TwapOracle.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockERC20Decimals} from "./mocks/MockERC20.sol";
import {MockWstETH, MockAggregator} from "./mocks/MockChainlink.sol";
import {MockUniswapV3Factory, MockUniswapV3Pool} from "./mocks/MockUniswapV3.sol";

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
