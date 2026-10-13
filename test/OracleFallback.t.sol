// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockWstETH, MockAggregator} from "./mocks/MockChainlink.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {INFToken} from "../src/INFToken.sol";

contract OracleFallbackTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant NOW = 10 days;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal collateral;
    MockAggregator internal primaryFeed;
    MockOracle internal fallbackOracle;
    WstEthUsdOracle internal oracle;
    NaNReserve internal reserve;

    function setUp() public {
        vm.warp(NOW);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        MockWstETH accountingRate = new MockWstETH(WAD);
        primaryFeed = new MockAggregator(8, 3_000e8, NOW);
        fallbackOracle = new MockOracle(3_100 * WAD);
        oracle = new WstEthUsdOracle(
            IWstETH(address(accountingRate)), IAggregatorV3(address(primaryFeed)), fallbackOracle, 1 hours, 200
        );
        reserve = new NaNReserve(collateral, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);

        collateral.mint(ALICE, 200 * WAD);
        collateral.mint(BOB, 200 * WAD);
        vm.prank(ALICE);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(BOB);
        collateral.approve(address(reserve), type(uint256).max);

        vm.prank(ALICE);
        reserve.fund(100 * WAD, 0, ALICE);
        vm.prank(BOB);
        reserve.mint(100 * WAD, 0, BOB);
    }

    function testLaggingFallbackCannotTransferJuniorEquityDuringOutage() public {
        fallbackOracle.setPrice(3_000 * WAD);
        primaryFeed.setUnavailable(true);
        // The legacy router still exposes a lagging diagnostic quote; reserve payouts reject it.
        (uint256 diagnostic, bool diagnosticFallback) = oracle.redemptionPrice();
        assertEq(diagnostic, 3_060 * WAD);
        assertTrue(diagnosticFallback);
        uint256 debtBefore = reserve.debtUsd();
        uint256 collateralBefore = reserve.reserveCollateral();
        uint256 bobBefore = collateral.balanceOf(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.redemptionCollateralPriceUsd();
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.nanRedemptionPriceUsd();
        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.redeem(100_000 * WAD, 0, BOB);
        assertEq(reserve.debtUsd(), debtBefore);
        assertEq(reserve.reserveCollateral(), collateralBefore);
        assertEq(collateral.balanceOf(BOB), bobBefore);

        primaryFeed.setUnavailable(false);
        primaryFeed.setRoundData(2, 4_000e8, block.timestamp, 2);
        uint256 equityBefore = reserve.equityUsd();
        vm.prank(BOB);
        uint256 out = reserve.redeem(100_000 * WAD, 0, BOB);
        assertEq(out, 24.975e18);
        assertEq(reserve.equityUsd(), equityBefore + 100e18);
    }

    function testStaleTimestampHaltsRedemptionDespiteHealthyFallback() public {
        vm.warp(NOW + 1 hours + 1);
        vm.prank(BOB);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.redeem(1_000 * WAD, 0, BOB);
        primaryFeed.setRoundData(2, 3_000e8, block.timestamp, 2);
        vm.prank(BOB);
        assertGt(reserve.redeem(1_000 * WAD, 0, BOB), 0);
    }

    function testFuzzFallbackPriceCannotAuthorizeOutagePayout(uint96 rawPrice) public {
        primaryFeed.setUnavailable(true);
        fallbackOracle.setPrice(uint256(rawPrice));
        uint256 debt = reserve.debtUsd();
        uint256 backing = reserve.reserveCollateral();
        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.redeem(1_000 * WAD, 0, BOB);
        assertEq(reserve.debtUsd(), debt);
        assertEq(reserve.reserveCollateral(), backing);
    }

    function testAuthorizerCanReplaceRetiredPrimaryFeedWithNewRouter() public {
        primaryFeed.setUnavailable(true);
        vm.expectRevert();
        reserve.collateralPriceUsd();

        MockAggregator replacementFeed = new MockAggregator(8, 3_200e8, block.timestamp);
        WstEthUsdOracle replacementRouter = new WstEthUsdOracle(
            IWstETH(address(new MockWstETH(WAD))), IAggregatorV3(address(replacementFeed)), fallbackOracle, 1 hours, 200
        );
        reserve.setOracle(replacementRouter);

        assertEq(reserve.collateralPriceUsd(), 3_200 * WAD);
        (uint256 redemptionPrice, bool fallbackUsed) = reserve.redemptionCollateralPriceUsd();
        assertEq(redemptionPrice, 3_200 * WAD);
        assertFalse(fallbackUsed);
    }

    function testStalePrimaryHaltsRiskAndJuniorActions() public {
        INFToken inf = reserve.inf();
        vm.prank(ALICE);
        inf.approve(address(reserve), 1 * WAD);
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(1 * WAD);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        primaryFeed.setUnavailable(true);

        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.mint(1 * WAD, 0, BOB);

        vm.prank(ALICE);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.fund(1 * WAD, 0, ALICE);

        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.settleDefundEpoch(series, epoch);

        vm.prank(ALICE);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.fund(1 * WAD, 0, ALICE);
    }

    function testBothSourcesUnavailableHaltsRedemption() public {
        primaryFeed.setUnavailable(true);
        fallbackOracle.setPrice(0);

        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.redeem(1 * WAD, 0, BOB);
    }

    function testOutageCannotStartRecoveryOrAllowCheckpoint() public {
        primaryFeed.setUnavailable(true);
        fallbackOracle.setPrice(1_000 * WAD);
        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.redeem(1_000 * WAD, 0, BOB);
        (, uint256 initial,,) = reserve.recovery();
        assertEq(initial, 0);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.checkpointRecovery();
    }

    function testOutageCannotClearRecoveryAndOutageTimeStillCounts() public {
        primaryFeed.setRoundData(2, 1_000e8, block.timestamp, 2);
        reserve.checkpointRecovery();
        (uint256 start, uint256 initial,,) = reserve.recovery();
        primaryFeed.setUnavailable(true);
        vm.warp(block.timestamp + 1 days);
        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.redeem(1_000 * WAD, 0, BOB);
        (uint256 afterStart, uint256 afterInitial,,) = reserve.recovery();
        assertEq(afterStart, start);
        assertEq(afterInitial, initial);
        primaryFeed.setUnavailable(false);
        primaryFeed.setRoundData(3, 1_000e8, block.timestamp, 3);
        assertEq(reserve.recoveryFloorPriceUsd(), initial >> 1);
    }

    function testRestoredPrimaryAllowsInsolventRedemptionAndRestart() public {
        primaryFeed.setUnavailable(true);
        fallbackOracle.setPrice(1_000 * WAD);
        uint256 balance = reserve.nan().balanceOf(BOB);
        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.redeem(balance, 0, BOB);
        primaryFeed.setUnavailable(false);
        primaryFeed.setRoundData(2, 1_000e8, block.timestamp, 2);
        uint256 backing = reserve.reserveCollateral();
        vm.prank(BOB);
        assertEq(reserve.redeem(balance, 0, BOB), backing);
        assertEq(reserve.reserveCollateral(), 0);
        assertEq(reserve.debtUsd(), 0);
        uint256 oldSupply = reserve.inf().totalSupply();
        uint256 quote = reserve.previewFund(WAD);
        vm.prank(BOB);
        uint256 out = reserve.fund(WAD, quote, BOB);
        assertEq(out, quote);
        assertEq(reserve.inf().balanceOf(ALICE), oldSupply);
        assertEq(reserve.inf().totalSupply(), oldSupply + out);
        assertEq(reserve.juniorSeries(), 1);
    }
}
