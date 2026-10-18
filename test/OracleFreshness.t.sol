// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockWstETH, MockAggregator} from "./mocks/MockChainlink.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract OracleFreshnessTest is Test {
    uint256 internal constant NOW = 10 days;
    uint256 internal constant HEARTBEAT = 1 hours;
    uint256 internal constant MAX_AGE = 75 minutes;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal collateral;
    MockWstETH internal accountingRate;
    MockAggregator internal feed;
    MockOracle internal fallbackOracle;
    WstEthUsdOracle internal oracle;
    NaNReserve internal reserve;

    function setUp() public {
        vm.warp(NOW);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        accountingRate = new MockWstETH(1e18);
        feed = new MockAggregator(8, 3_000e8, NOW);
        fallbackOracle = new MockOracle(3_100e18);
        oracle = _router(MAX_AGE);
        reserve = new NaNReserve(collateral, oracle, address(this), 6_450, 6_500, 10, 10);
        collateral.mint(ALICE, 200e18);
        collateral.mint(BOB, 200e18);
        vm.startPrank(ALICE);
        collateral.approve(address(reserve), 200e18);
        reserve.fund(100e18, 0, ALICE);
        vm.stopPrank();
        vm.startPrank(BOB);
        collateral.approve(address(reserve), 200e18);
        reserve.mint(100e18, 0, BOB);
        vm.stopPrank();
    }

    function testHeartbeatWithPublicationDelaySupportsPricedOperations() public {
        (uint256 series, uint256 epoch) = _request();
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        feed.setRoundData(2, 3_000e8, block.timestamp, 2);
        uint256 publishedAt = block.timestamp;
        vm.warp(publishedAt + HEARTBEAT);
        assertEq(reserve.collateralPriceUsd(), 3_000e18);
        // No update at the nominal heartbeat: allow the bounded publication margin.
        vm.warp(publishedAt + MAX_AGE);
        vm.prank(ALICE);
        assertGt(reserve.fund(1e18, 0, ALICE), 0);
        vm.prank(BOB);
        assertGt(reserve.mint(1e18, 0, BOB), 0);
        vm.prank(BOB);
        assertGt(reserve.redeem(1_000e18, 0, BOB), 0);
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 paid, uint256 refund) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertGt(paid, 0);
        assertEq(refund, 0);
        // The next ordinary publication starts a new freshness interval.
        feed.setRoundData(3, 3_000e8, block.timestamp, 3);
        vm.warp(block.timestamp + HEARTBEAT);
        assertEq(reserve.collateralPriceUsd(), 3_000e18);
    }

    function testOutageHaltsAllPricedActionsDespiteHealthyFallback() public {
        (uint256 series, uint256 epoch) = _request();
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        feed.setRoundData(2, 3_000e8, block.timestamp, 2);
        vm.warp(block.timestamp + MAX_AGE + 1);
        uint256 backing = reserve.reserveCollateral();
        uint256 debt = reserve.debtUsd();
        vm.prank(ALICE);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.fund(1e18, 0, ALICE);
        vm.prank(BOB);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.mint(1e18, 0, BOB);
        vm.prank(BOB);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.redeem(1_000e18, 0, BOB);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.settleDefundEpoch(series, epoch);
        assertEq(reserve.reserveCollateral(), backing);
        assertEq(reserve.debtUsd(), debt);
        (uint256 diagnostic, bool fallbackUsed) = oracle.redemptionPrice();
        assertGt(diagnostic, 0);
        assertTrue(fallbackUsed);
        feed.setRoundData(3, 3_000e8, block.timestamp, 3);
        reserve.settleDefundEpoch(series, epoch);
    }

    function testFixedCollateralClaimRemainsAvailableWhenPrimaryBecomesStale() public {
        (uint256 series, uint256 epoch) = _request();
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        feed.setRoundData(2, 3_000e8, block.timestamp, 2);
        reserve.settleDefundEpoch(series, epoch);
        uint256 claimable = reserve.claimableWithdrawalCollateral();
        assertGt(claimable, 0);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.prank(ALICE);
        (uint256 paid, uint256 refund) = reserve.claimDefund(series, epoch, claimable, ALICE);
        assertEq(paid, claimable);
        assertEq(refund, 0);
    }

    function testExpiredRequestCanBeRefundedDuringStalePrimaryOutage() public {
        vm.warp(NOW + MAX_AGE + 1);
        // Requesting, expiring and refunding INF are all oracle-free.
        (uint256 series, uint256 epoch) = _request();
        vm.warp(reserve.withdrawalExpiry(series, epoch));
        reserve.expireDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 paid, uint256 refund) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(paid, 0);
        assertEq(refund, 1e18);
    }

    function testDebtFreeSettlementRemainsAvailableDuringStalePrimaryOutage() public {
        uint256 nanBalance = reserve.nan().balanceOf(BOB);
        vm.prank(BOB);
        reserve.redeem(nanBalance, 0, BOB);
        assertEq(reserve.debtUsd(), 0);
        (uint256 series, uint256 epoch) = _request();
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        oracle.price();
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 paid, uint256 refund) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertGt(paid, 0);
        assertEq(refund, 0);
    }

    function testChangingImmutableFreshnessRequiresRouterRotation() public {
        vm.warp(NOW + MAX_AGE + 1);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.collateralPriceUsd();
        WstEthUsdOracle replacement = _router(90 minutes);
        reserve.setOracle(replacement);
        assertEq(reserve.collateralPriceUsd(), 3_000e18);
        assertEq(oracle.maxStaleness(), MAX_AGE);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        oracle.price();
        vm.prank(BOB);
        assertGt(reserve.redeem(1_000e18, 0, BOB), 0);
    }

    function _request() internal returns (uint256 series, uint256 epoch) {
        vm.startPrank(ALICE);
        reserve.inf().approve(address(reserve), 1e18);
        (series, epoch) = reserve.requestDefund(1e18);
        vm.stopPrank();
    }

    function _router(uint256 maxAge) internal returns (WstEthUsdOracle) {
        return new WstEthUsdOracle(
            IWstETH(address(accountingRate)), IAggregatorV3(address(feed)), fallbackOracle, maxAge, 200
        );
    }
}
