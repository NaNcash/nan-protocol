// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockWstETH, MockAggregator} from "./mocks/MockChainlink.sol";

contract WstEthUsdOracleTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant NOW = 10 days;
    uint256 internal constant MAX_STALENESS = 1 hours;

    MockWstETH internal wstETH;
    MockAggregator internal ethUsd;
    MockAggregator internal stEthEth;
    WstEthUsdOracle internal oracle;

    function setUp() public {
        vm.warp(NOW);
        wstETH = new MockWstETH(1.2e18);
        ethUsd = new MockAggregator(8, 3_000e8, NOW);
        stEthEth = new MockAggregator(18, 0.98e18, NOW);
        oracle = new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(ethUsd)), IAggregatorV3(address(stEthEth)), MAX_STALENESS
        );
    }

    function testUsesMarketDiscountWhenStEthDepegs() public view {
        assertEq(oracle.price(), 3_528 * WAD);
    }

    function testCapsStEthAtProtocolAccountingValue() public {
        stEthEth.setRoundData(2, 1.01e18, NOW, 2);
        assertEq(oracle.price(), 3_600 * WAD);
    }

    function testTracksWstEthAccountingRate() public {
        wstETH.setStEthPerToken(1.25e18);
        assertEq(oracle.price(), 3_675 * WAD);
    }

    function testRejectsStaleEthUsdFeed() public {
        ethUsd.setRoundData(2, 3_000e8, NOW - MAX_STALENESS - 1, 2);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        oracle.price();
    }

    function testRejectsStaleStEthEthFeed() public {
        stEthEth.setRoundData(2, 0.98e18, NOW - MAX_STALENESS - 1, 2);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        oracle.price();
    }

    function testRejectsIncompleteRound() public {
        ethUsd.setRoundData(2, 3_000e8, NOW, 1);
        vm.expectRevert(WstEthUsdOracle.InvalidRound.selector);
        oracle.price();
    }

    function testRejectsNonPositiveFeedAnswer() public {
        stEthEth.setRoundData(2, 0, NOW, 2);
        vm.expectRevert(WstEthUsdOracle.InvalidPrice.selector);
        oracle.price();
    }

    function testRejectsFutureTimestamp() public {
        stEthEth.setRoundData(2, 0.98e18, NOW + 1, 2);
        vm.expectRevert(WstEthUsdOracle.InvalidPrice.selector);
        oracle.price();
    }

    function testRejectsZeroWstEthRate() public {
        wstETH.setStEthPerToken(0);
        vm.expectRevert(WstEthUsdOracle.InvalidPrice.selector);
        oracle.price();
    }

    function testConstructorValidation() public {
        vm.expectRevert(WstEthUsdOracle.ZeroAddress.selector);
        new WstEthUsdOracle(
            IWstETH(address(0)), IAggregatorV3(address(ethUsd)), IAggregatorV3(address(stEthEth)), MAX_STALENESS
        );

        vm.expectRevert(WstEthUsdOracle.InvalidConfiguration.selector);
        new WstEthUsdOracle(
            IWstETH(address(wstETH)), IAggregatorV3(address(ethUsd)), IAggregatorV3(address(stEthEth)), 0
        );

        MockAggregator tooPrecise = new MockAggregator(19, 1e18, NOW);
        vm.expectRevert(WstEthUsdOracle.UnsupportedFeedDecimals.selector);
        new WstEthUsdOracle(
            IWstETH(address(wstETH)),
            IAggregatorV3(address(tooPrecise)),
            IAggregatorV3(address(stEthEth)),
            MAX_STALENESS
        );
    }
}
