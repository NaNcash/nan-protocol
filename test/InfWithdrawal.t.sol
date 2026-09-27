// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {INFToken} from "../src/INFToken.sol";

contract InfWithdrawalTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    INFToken internal inf;

    function setUp() public {
        vm.warp(10 days + 1 hours);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        inf = reserve.inf();

        collateral.mint(ALICE, 2_000 * WAD);
        collateral.mint(BOB, 2_000 * WAD);
        vm.startPrank(ALICE);
        collateral.approve(address(reserve), type(uint256).max);
        inf.approve(address(reserve), type(uint256).max);
        reserve.fund(100 * WAD, 0, ALICE);
        vm.stopPrank();
        vm.prank(BOB);
        collateral.approve(address(reserve), type(uint256).max);
    }

    function _mintDebt() internal {
        vm.prank(BOB);
        reserve.mint(180 * WAD, 0, BOB);
    }

    function testThreeDayMinimumAndExpiredRequestCanBeReclaimed() public {
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(10 * WAD);

        assertGe(reserve.withdrawalMaturity(series, epoch) - block.timestamp, 3 days);
        assertLt(reserve.withdrawalMaturity(series, epoch) - block.timestamp, 4 days);
        vm.expectRevert(NaNReserve.WithdrawalNotReady.selector);
        reserve.settleDefundEpoch(series, epoch);

        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.WithdrawalRequestExists.selector);
        reserve.requestDefund(1);

        vm.warp(reserve.withdrawalExpiry(series, epoch));
        vm.expectRevert(NaNReserve.WithdrawalWindowClosed.selector);
        reserve.settleDefundEpoch(series, epoch);
        reserve.expireDefundEpoch(series, epoch);

        vm.prank(ALICE);
        (uint256 collateralOut, uint256 refundedInf) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(collateralOut, 0);
        assertEq(refundedInf, 10 * WAD);
    }

    function testDelayUpdateIsSnapshottedPerDailyCohort() public {
        vm.prank(ALICE);
        assertTrue(inf.transfer(BOB, 10 * WAD));
        vm.prank(BOB);
        inf.approve(address(reserve), type(uint256).max);

        vm.prank(ALICE);
        (uint256 series, uint256 firstEpoch) = reserve.requestDefund(10 * WAD);
        uint256 firstMaturity = reserve.withdrawalMaturity(series, firstEpoch);

        reserve.setInfWithdrawalDelay(1 days);
        vm.prank(BOB);
        (uint256 bobSeries, uint256 bobEpoch) = reserve.requestDefund(10 * WAD);
        assertEq(bobSeries, series);
        assertEq(bobEpoch, firstEpoch);
        assertEq(reserve.withdrawalMaturity(series, firstEpoch), firstMaturity);

        vm.warp((firstEpoch + 1) * 1 days + 1);
        vm.prank(ALICE);
        (uint256 nextSeries, uint256 nextEpoch) = reserve.requestDefund(10 * WAD);
        assertEq(nextSeries, series);
        assertEq(nextEpoch, firstEpoch + 1);
        uint256 nextMaturity = reserve.withdrawalMaturity(series, nextEpoch);
        assertLt(nextMaturity, firstMaturity);
        assertGe(nextMaturity - block.timestamp, 1 days);

        vm.warp(nextMaturity);
        reserve.settleDefundEpoch(series, nextEpoch);
        vm.expectRevert(NaNReserve.WithdrawalNotReady.selector);
        reserve.settleDefundEpoch(series, firstEpoch);
        vm.warp(firstMaturity);
        reserve.settleDefundEpoch(series, firstEpoch);
    }

    function testLengtheningDelayCannotTrapExistingRequest() public {
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(10 * WAD);
        uint256 originalMaturity = reserve.withdrawalMaturity(series, epoch);
        uint256 originalExpiry = reserve.withdrawalExpiry(series, epoch);

        reserve.setInfWithdrawalDelay(30 days);
        assertEq(reserve.withdrawalMaturity(series, epoch), originalMaturity);
        assertEq(reserve.withdrawalExpiry(series, epoch), originalExpiry);
        vm.warp(originalMaturity);
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 collateralOut,) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertGt(collateralOut, 0);
    }

    function testMaturityQueriesRejectUnopenedCohort() public {
        vm.expectRevert(NaNReserve.NoWithdrawalRequest.selector);
        reserve.withdrawalMaturity(1, 10);
        vm.expectRevert(NaNReserve.NoWithdrawalRequest.selector);
        reserve.withdrawalExpiry(1, 10);
    }

    function testEpochChangePreservesCurrentCohortAndAppliesAtBoundary() public {
        vm.prank(ALICE);
        assertTrue(inf.transfer(BOB, 10 * WAD));
        vm.prank(BOB);
        inf.approve(address(reserve), type(uint256).max);
        (uint256 currentEpoch, uint256 closesAt) = reserve.currentWithdrawalEpoch();
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(10 * WAD);
        assertEq(epoch, currentEpoch);
        uint256 maturity = reserve.withdrawalMaturity(series, epoch);
        uint256 expiry = reserve.withdrawalExpiry(series, epoch);

        reserve.setInfWithdrawalEpoch(6 hours);
        (uint256 unchangedEpoch, uint256 unchangedClose) = reserve.currentWithdrawalEpoch();
        assertEq(unchangedEpoch, epoch);
        assertEq(unchangedClose, closesAt);
        vm.prank(BOB);
        (, uint256 bobEpoch) = reserve.requestDefund(10 * WAD);
        assertEq(bobEpoch, epoch);
        assertEq(reserve.withdrawalMaturity(series, epoch), maturity);
        assertEq(reserve.withdrawalExpiry(series, epoch), expiry);
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.WithdrawalRequestExists.selector);
        reserve.requestDefund(1);

        vm.warp(closesAt);
        (uint256 nextEpoch, uint256 nextClose) = reserve.currentWithdrawalEpoch();
        assertEq(nextEpoch, epoch + 1);
        assertEq(nextClose, closesAt + 6 hours);
        vm.prank(ALICE);
        (, uint256 requestedEpoch) = reserve.requestDefund(10 * WAD);
        assertEq(requestedEpoch, nextEpoch);
        assertEq(reserve.withdrawalMaturity(series, nextEpoch), nextClose + 3 days);

        vm.warp(maturity);
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 collateralOut,) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertGt(collateralOut, 0);
    }

    function testRepeatedEpochUpdatesCannotMoveCurrentBoundary() public {
        (uint256 epoch, uint256 closesAt) = reserve.currentWithdrawalEpoch();
        reserve.setInfWithdrawalEpoch(7 days);
        vm.warp(closesAt - 1);
        reserve.setInfWithdrawalEpoch(1 hours);
        (uint256 currentEpoch, uint256 currentClose) = reserve.currentWithdrawalEpoch();
        assertEq(currentEpoch, epoch);
        assertEq(currentClose, closesAt);
        assertEq(reserve.withdrawalEpochScheduleFirstId(), epoch + 1);
        assertEq(reserve.withdrawalEpochScheduleStart(), closesAt);

        vm.warp(closesAt);
        (currentEpoch, currentClose) = reserve.currentWithdrawalEpoch();
        assertEq(currentEpoch, epoch + 1);
        assertEq(currentClose, closesAt + 1 hours);
        reserve.setInfWithdrawalEpoch(7 days);
        vm.warp(currentClose);
        (uint256 laterEpoch, uint256 laterClose) = reserve.currentWithdrawalEpoch();
        assertEq(laterEpoch, epoch + 2);
        assertEq(laterClose, currentClose + 7 days);
    }

    function testLongerEpochCannotDelayExistingExpiry() public {
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(10 * WAD);
        uint256 expiry = reserve.withdrawalExpiry(series, epoch);
        reserve.setInfWithdrawalEpoch(7 days);
        vm.warp(expiry);
        reserve.expireDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (, uint256 refundedInf) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(refundedInf, 10 * WAD);
    }

    function testFuzzEpochIdsNeverCollideAcrossLengthChanges(uint32 rawFirst, uint32 rawSecond, uint32 rawAdvance)
        public
    {
        uint256 firstLength = bound(uint256(rawFirst), 1 hours, 7 days);
        uint256 secondLength = bound(uint256(rawSecond), 1 hours, 7 days);
        uint256 advance = bound(uint256(rawAdvance), 0, 100 days);
        (uint256 originalEpoch, uint256 boundary) = reserve.currentWithdrawalEpoch();
        reserve.setInfWithdrawalEpoch(firstLength);
        vm.warp(boundary + advance);
        (uint256 epoch, uint256 closesAt) = reserve.currentWithdrawalEpoch();
        assertEq(epoch, originalEpoch + 1 + advance / firstLength);
        assertGt(closesAt, block.timestamp);
        reserve.setInfWithdrawalEpoch(secondLength);
        (uint256 sameEpoch, uint256 sameClose) = reserve.currentWithdrawalEpoch();
        assertEq(sameEpoch, epoch);
        assertEq(sameClose, closesAt);
        vm.warp(closesAt);
        (uint256 nextEpoch, uint256 nextClose) = reserve.currentWithdrawalEpoch();
        assertEq(nextEpoch, epoch + 1);
        assertEq(nextClose, closesAt + secondLength);
    }

    function testTemporaryPriceSpikeDoesNotSetWithdrawalPayout() public {
        _mintDebt();
        oracle.setPrice(3_500 * WAD);
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(1_000 * WAD);

        oracle.setPrice(3_000 * WAD);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);

        uint256 expectedUsd = 1_000 * WAD * (840_000 - 539_460) / 300_000;
        uint256 expectedCollateral = expectedUsd / 3_000;
        vm.prank(ALICE);
        (uint256 collateralOut, uint256 refundedInf) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(collateralOut, expectedCollateral);
        assertEq(refundedInf, 0);
    }

    function testLimitedCapacityIsSharedProRataWithoutTrappedDust() public {
        _mintDebt();
        vm.prank(ALICE);
        assertTrue(inf.transfer(BOB, 20_000 * WAD));
        vm.prank(BOB);
        inf.approve(address(reserve), type(uint256).max);

        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(20_000 * WAD);
        vm.prank(BOB);
        reserve.requestDefund(20_000 * WAD);

        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filledInf, uint256 totalCollateralOut,,) = reserve.withdrawalEpochs(series, epoch);
        assertGt(filledInf, 0);
        assertLt(filledInf, 40_000 * WAD);
        assertEq(reserve.claimableWithdrawalCollateral(), totalCollateralOut);

        vm.prank(BOB);
        (uint256 bobCollateral, uint256 bobRefund) = reserve.claimDefund(series, epoch, 0, BOB);
        vm.prank(ALICE);
        (uint256 aliceCollateral, uint256 aliceRefund) = reserve.claimDefund(series, epoch, 0, ALICE);

        assertApproxEqAbs(aliceCollateral, bobCollateral, 1);
        assertApproxEqAbs(aliceRefund, bobRefund, 1);
        assertEq(aliceCollateral + bobCollateral, totalCollateralOut);
        assertEq(aliceRefund + bobRefund + filledInf, 40_000 * WAD);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        assertLe(reserve.debtRatioBps(), 6_500);
    }

    function testSettledCollateralIsExcludedFromSeniorBacking() public {
        _mintDebt();
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(5_000 * WAD);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);

        uint256 claimable = reserve.claimableWithdrawalCollateral();
        assertGt(claimable, 0);
        assertEq(collateral.balanceOf(address(reserve)), reserve.reserveCollateral() + claimable);

        oracle.setPrice(1_500 * WAD);
        uint256 bobNan = reserve.nan().balanceOf(BOB);
        vm.prank(BOB);
        reserve.redeem(bobNan, 0, BOB);
        assertEq(reserve.reserveCollateral(), 0);
        assertEq(collateral.balanceOf(address(reserve)), claimable);

        vm.prank(ALICE);
        (uint256 collateralOut,) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(collateralOut, claimable);
        assertEq(collateral.balanceOf(address(reserve)), 0);
    }

    function testRetiredSeriesRequestCannotClaimFromNewSeries() public {
        _mintDebt();
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(10_000 * WAD);
        oracle.setPrice(1_500 * WAD);
        vm.prank(BOB);
        reserve.recapitalize(278 * WAD, 0, BOB);

        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 collateralOut, uint256 refundedInf) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(collateralOut, 0);
        assertEq(refundedInf, 10_000 * WAD);
        assertEq(reserve.juniorSeries(), 2);
    }

    function testDebtFreeWithdrawalDoesNotNeedOracle() public {
        uint256 infSupply = inf.totalSupply();
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(infSupply);
        oracle.setPrice(0);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 collateralOut,) = reserve.claimDefund(series, epoch, 100 * WAD, ALICE);
        assertEq(collateralOut, 100 * WAD);
    }

    function testOracleFailureAllowsExpiryAndRefund() public {
        _mintDebt();
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(10 * WAD);
        oracle.setPrice(0);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.settleDefundEpoch(series, epoch);

        vm.warp(reserve.withdrawalExpiry(series, epoch));
        reserve.expireDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 collateralOut, uint256 refundedInf) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(collateralOut, 0);
        assertEq(refundedInf, 10 * WAD);
    }

    function testFuzzPartialFillConservesInfAndCollateral(uint96 rawAlice, uint96 rawBob) public {
        _mintDebt();
        uint256 aliceAmount = bound(uint256(rawAlice), 1 * WAD, 20_000 * WAD);
        uint256 bobAmount = bound(uint256(rawBob), 1 * WAD, 20_000 * WAD);
        vm.prank(ALICE);
        assertTrue(inf.transfer(BOB, bobAmount));
        vm.prank(BOB);
        inf.approve(address(reserve), bobAmount);

        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(aliceAmount);
        vm.prank(BOB);
        reserve.requestDefund(bobAmount);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filledInf, uint256 payout,,) = reserve.withdrawalEpochs(series, epoch);

        vm.prank(BOB);
        (uint256 bobOut, uint256 bobRefund) = reserve.claimDefund(series, epoch, 0, BOB);
        vm.prank(ALICE);
        (uint256 aliceOut, uint256 aliceRefund) = reserve.claimDefund(series, epoch, 0, ALICE);

        assertEq(aliceOut + bobOut, payout);
        assertEq(aliceRefund + bobRefund + filledInf, aliceAmount + bobAmount);
        assertLe(aliceRefund, aliceAmount);
        assertLe(bobRefund, bobAmount);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        assertLe(reserve.debtRatioBps(), reserve.maxDebtRatioBps());
    }

    function testFuzzSettlementNeverBreaksDebtLimit(uint96 rawPrice, uint96 rawInf) public {
        _mintDebt();
        uint256 infAmount = bound(uint256(rawInf), 1, inf.balanceOf(ALICE));
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(infAmount);
        oracle.setPrice(bound(uint256(rawPrice), 1_500 * WAD, 6_000 * WAD));
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);

        (,, uint256 filledInf, uint256 payout,,) = reserve.withdrawalEpochs(series, epoch);
        if (filledInf != 0) assertLe(reserve.debtRatioBps(), reserve.maxDebtRatioBps());
        assertEq(reserve.claimableWithdrawalCollateral(), payout);
        assertEq(collateral.balanceOf(address(reserve)), reserve.reserveCollateral() + payout);
    }
}
