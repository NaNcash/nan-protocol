// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {LocalWstETH} from "../src/local/LocalWstETH.sol";
import {LocalStEthUsdFeed} from "../src/local/LocalStEthUsdFeed.sol";
import {LocalFallbackOracle} from "../src/local/LocalFallbackOracle.sol";

contract LocalTestnetTest is Test {
    LocalWstETH internal collateral;
    LocalStEthUsdFeed internal feed;
    LocalFallbackOracle internal fallbackOracle;
    WstEthUsdOracle internal oracle;
    NaNReserve internal reserve;

    function setUp() public {
        vm.warp(10 days);
        collateral = new LocalWstETH();
        feed = new LocalStEthUsdFeed();
        fallbackOracle = new LocalFallbackOracle();
        oracle = new WstEthUsdOracle(
            IWstETH(address(collateral)), IAggregatorV3(address(feed)), fallbackOracle, 1 hours, 200
        );
        reserve = new NaNReserve(collateral, oracle, address(this), 3_000, 5_500, 6_500, 10, 10);
        collateral.faucet(500 ether);
        collateral.approve(address(reserve), type(uint256).max);
    }

    function testFaucetRateAndPrimaryPrice() public {
        assertEq(collateral.balanceOf(address(this)), 500 ether);
        assertEq(reserve.collateralPriceUsd(), 3_000 ether);
        collateral.setStEthPerToken(1.1 ether);
        assertEq(reserve.collateralPriceUsd(), 3_300 ether);
        feed.setAnswer(2_000e8);
        assertEq(reserve.collateralPriceUsd(), 2_200 ether);
        vm.expectRevert(LocalWstETH.InvalidFaucetAmount.selector);
        collateral.faucet(1_001 ether);
        vm.expectRevert(LocalWstETH.InvalidRate.selector);
        collateral.setStEthPerToken(0);
    }

    function testTimeTravelKeepsHealthyFeedFreshAndFallbackSwitches() public {
        vm.warp(block.timestamp + 5 days);
        assertEq(reserve.collateralPriceUsd(), 3_000 ether);
        feed.setStale(true);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.collateralPriceUsd();
        (uint256 redemptionPrice, bool fallbackUsed) = reserve.redemptionCollateralPriceUsd();
        assertEq(redemptionPrice, 3_060 ether);
        assertTrue(fallbackUsed);
        feed.setStale(false);
        feed.setUnavailable(true);
        (, fallbackUsed) = reserve.redemptionCollateralPriceUsd();
        assertTrue(fallbackUsed);
        fallbackOracle.setPrice(0);
        vm.expectRevert(WstEthUsdOracle.FallbackUnavailable.selector);
        reserve.redemptionCollateralPriceUsd();
    }

    function testLocalLifecycleThroughRealReserve() public {
        reserve.fund(100 ether, 0, address(this));
        reserve.mint(180 ether, 0, address(this));
        assertEq(reserve.debtUsd(), 539_460 ether);
        feed.setAnswer(1_500e8);
        reserve.checkpointRecovery();
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Insolvent));
        uint256 quote = reserve.previewFund(10 ether);
        reserve.fund(10 ether, quote, address(this));
        assertEq(address(reserve.inf().reserve()), address(reserve));
        assertGt(reserve.inf().totalSupply(), 300_000 ether);
        feed.setAnswer(4_000e8);
        reserve.nan().approve(address(reserve), 1_000 ether);
        reserve.redeem(1_000 ether, 0, address(this));

        reserve.inf().approve(address(reserve), 1_000 ether);
        (uint256 series, uint256 epoch) = reserve.requestDefund(1_000 ether);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        (uint256 out,) = reserve.claimDefund(series, epoch, 0, address(this));
        assertGt(out, 0);
    }
}
