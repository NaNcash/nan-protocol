// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockWstETH, MockAggregator} from "./mocks/MockChainlink.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

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
        reserve = new NaNReserve(collateral, oracle, 6_500, 10, 10);

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

    function testStalePrimaryStillAllowsConservativeRedemption() public {
        primaryFeed.setUnavailable(true);
        (uint256 price, bool fallbackUsed) = reserve.redemptionCollateralPriceUsd();
        assertEq(price, 3_162 * WAD);
        assertTrue(fallbackUsed);
        assertEq(reserve.nanRedemptionPriceUsd(), WAD);

        uint256 debtBefore = reserve.debtUsd();
        uint256 collateralBefore = reserve.reserveCollateral();
        vm.prank(BOB);
        uint256 collateralOut = reserve.redeem(10_000 * WAD, 0, BOB);

        assertEq(reserve.debtUsd(), debtBefore - 10_000 * WAD);
        assertEq(reserve.reserveCollateral(), collateralBefore - collateralOut);
        assertEq(collateralOut, 10_000 * WAD * 9_990 / 10_000 / 3_162);
    }

    function testStalePrimaryHaltsRiskAndJuniorActions() public {
        primaryFeed.setUnavailable(true);

        vm.prank(BOB);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.mint(1 * WAD, 0, BOB);

        vm.prank(ALICE);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.fund(1 * WAD, 0, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.defund(1 * WAD, 0, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(MockAggregator.FeedUnavailable.selector);
        reserve.recapitalize(1 * WAD, 0, ALICE);
    }

    function testBothSourcesUnavailableHaltsRedemption() public {
        primaryFeed.setUnavailable(true);
        fallbackOracle.setPrice(0);

        vm.prank(BOB);
        vm.expectRevert(WstEthUsdOracle.FallbackUnavailable.selector);
        reserve.redeem(1 * WAD, 0, BOB);
    }
}
