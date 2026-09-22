// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockWstETH, MockAggregator} from "./mocks/MockChainlink.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract RevertingOracle is IPriceOracle {
    bool public unavailable;

    function setUnavailable(bool unavailable_) external {
        unavailable = unavailable_;
    }

    function price() external view returns (uint256) {
        if (unavailable) revert("unavailable");
        return 3_500e18;
    }
}

contract WstEthUsdOracleTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant NOW = 10 days;
    uint256 internal constant MAX_STALENESS = 1 hours;

    MockWstETH internal wstETH;
    MockAggregator internal stEthUsd;
    MockOracle internal fallbackOracle;
    WstEthUsdOracle internal oracle;

    function setUp() public {
        vm.warp(NOW);
        wstETH = new MockWstETH(1.2e18);
        stEthUsd = new MockAggregator(8, 2_940e8, NOW);
        fallbackOracle = new MockOracle(3_500 * WAD);
        oracle = new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(stEthUsd)), fallbackOracle, MAX_STALENESS, 200
        );
    }

    function testUsesDirectStEthUsdFeed() public view {
        assertEq(oracle.price(), 3_528 * WAD);
        (uint256 redemptionPrice, bool fallbackUsed) = oracle.redemptionPrice();
        assertEq(redemptionPrice, 3_528 * WAD);
        assertFalse(fallbackUsed);
    }

    function testTracksWstEthAccountingRate() public {
        wstETH.setStEthPerToken(1.25e18);
        assertEq(oracle.price(), 3_675 * WAD);
    }

    function testStalePrimaryUsesPremiumFallbackForRedemptionOnly() public {
        stEthUsd.setRoundData(2, 2_940e8, NOW - MAX_STALENESS - 1, 2);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        oracle.price();

        (uint256 redemptionPrice, bool fallbackUsed) = oracle.redemptionPrice();
        assertEq(redemptionPrice, 3_570 * WAD);
        assertTrue(fallbackUsed);
    }

    function testRevertingPrimaryUsesFallback() public {
        stEthUsd.setUnavailable(true);
        (uint256 redemptionPrice, bool fallbackUsed) = oracle.redemptionPrice();
        assertEq(redemptionPrice, 3_570 * WAD);
        assertTrue(fallbackUsed);
    }

    function testIncompletePrimaryRoundUsesFallback() public {
        stEthUsd.setRoundData(2, 2_940e8, NOW, 1);
        vm.expectRevert(WstEthUsdOracle.InvalidRound.selector);
        oracle.price();
        (, bool fallbackUsed) = oracle.redemptionPrice();
        assertTrue(fallbackUsed);
    }

    function testInvalidPrimaryPriceUsesFallback() public {
        stEthUsd.setRoundData(2, 0, NOW, 2);
        vm.expectRevert(WstEthUsdOracle.InvalidPrice.selector);
        oracle.price();
        (, bool fallbackUsed) = oracle.redemptionPrice();
        assertTrue(fallbackUsed);
    }

    function testFuturePrimaryTimestampUsesFallback() public {
        stEthUsd.setRoundData(2, 2_940e8, NOW + 1, 2);
        vm.expectRevert(WstEthUsdOracle.InvalidPrice.selector);
        oracle.price();
        (, bool fallbackUsed) = oracle.redemptionPrice();
        assertTrue(fallbackUsed);
    }

    function testZeroWstEthRateUsesFallback() public {
        wstETH.setStEthPerToken(0);
        vm.expectRevert(WstEthUsdOracle.InvalidPrice.selector);
        oracle.price();
        (, bool fallbackUsed) = oracle.redemptionPrice();
        assertTrue(fallbackUsed);
    }

    function testInvalidFallbackHaltsRedemption() public {
        stEthUsd.setUnavailable(true);
        fallbackOracle.setPrice(0);
        vm.expectRevert(WstEthUsdOracle.FallbackUnavailable.selector);
        oracle.redemptionPrice();
    }

    function testRevertingFallbackHaltsRedemption() public {
        RevertingOracle revertingSource = new RevertingOracle();
        WstEthUsdOracle revertingFallback = new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(stEthUsd)), revertingSource, MAX_STALENESS, 200
        );
        stEthUsd.setUnavailable(true);
        revertingSource.setUnavailable(true);
        vm.expectRevert(WstEthUsdOracle.FallbackUnavailable.selector);
        revertingFallback.redemptionPrice();
    }

    function testHealthyPrimaryDoesNotReadFallback() public {
        WstEthUsdOracle revertingFallback = new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(stEthUsd)), new RevertingOracle(), MAX_STALENESS, 200
        );
        (uint256 redemptionPrice, bool fallbackUsed) = revertingFallback.redemptionPrice();
        assertEq(redemptionPrice, 3_528 * WAD);
        assertFalse(fallbackUsed);
    }

    function testFallbackPremiumRoundsUp() public {
        stEthUsd.setUnavailable(true);
        fallbackOracle.setPrice(1);
        (uint256 redemptionPrice,) = oracle.redemptionPrice();
        assertEq(redemptionPrice, 2);
    }

    function testConstructorValidation() public {
        vm.expectRevert(WstEthUsdOracle.ZeroAddress.selector);
        new WstEthUsdOracle(IWstETH(address(0)), IAggregatorV3(address(stEthUsd)), fallbackOracle, MAX_STALENESS, 200);

        vm.expectRevert(WstEthUsdOracle.ZeroAddress.selector);
        new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(stEthUsd)), IPriceOracle(address(0)), MAX_STALENESS, 200
        );

        vm.expectRevert(WstEthUsdOracle.FallbackUnavailable.selector);
        new WstEthUsdOracle(
            IWstETH(address(wstETH)),
            IAggregatorV3(address(stEthUsd)),
            IPriceOracle(address(0x1234)),
            MAX_STALENESS,
            200
        );

        fallbackOracle.setPrice(0);
        vm.expectRevert(WstEthUsdOracle.FallbackUnavailable.selector);
        new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(stEthUsd)), fallbackOracle, MAX_STALENESS, 200
        );
        fallbackOracle.setPrice(3_500 * WAD);

        vm.expectRevert(WstEthUsdOracle.InvalidConfiguration.selector);
        new WstEthUsdOracle(IWstETH(address(wstETH)), IAggregatorV3(address(stEthUsd)), fallbackOracle, 0, 200);

        vm.expectRevert(WstEthUsdOracle.InvalidConfiguration.selector);
        new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(stEthUsd)), fallbackOracle, MAX_STALENESS, 10_000
        );

        MockAggregator tooPrecise = new MockAggregator(19, 1e18, NOW);
        vm.expectRevert(WstEthUsdOracle.UnsupportedFeedDecimals.selector);
        new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(tooPrecise)), fallbackOracle, MAX_STALENESS, 200
        );
    }
}
