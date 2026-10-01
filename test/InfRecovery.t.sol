// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {INFToken} from "../src/INFToken.sol";

contract InfRecoveryTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    INFToken internal inf;

    function setUp() public {
        vm.warp(10 days);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        inf = reserve.inf();
        collateral.mint(ALICE, 10_000 * WAD);
        collateral.mint(BOB, 10_000 * WAD);
        vm.prank(ALICE);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(BOB);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(ALICE);
        inf.approve(address(reserve), type(uint256).max);
        vm.prank(ALICE);
        reserve.fund(100 * WAD, 0, ALICE);
        vm.prank(BOB);
        reserve.mint(180 * WAD, 0, BOB);
    }

    function _crash() internal {
        oracle.setPrice(1_500 * WAD);
        reserve.checkpointRecovery();
    }

    function testInitialFloorUsesBoundaryNavNotZeroEquity() public {
        _crash();
        uint256 boundaryEquity = Math.mulDiv(reserve.debtUsd(), 3_500, 6_500, Math.Rounding.Ceil);
        uint256 expected = Math.mulDiv(boundaryEquity, WAD, inf.totalSupply(), Math.Rounding.Ceil);
        assertEq(reserve.recoveryFloorPriceUsd(), expected);
        assertEq(reserve.fundingPriceUsd(), expected);
        assertEq(reserve.infPriceUsd(), 0);
        (uint256 startedAt,, uint256 period, uint256 exitRatio) = reserve.recovery();
        assertEq(startedAt, block.timestamp);
        assertEq(period, 1 days);
        assertEq(exitRatio, 6_450);
    }

    function testViewsDoNotStartDecayClock() public {
        oracle.setPrice(1_500 * WAD);
        uint256 price = reserve.recoveryFloorPriceUsd();
        reserve.previewFund(WAD);
        vm.warp(block.timestamp + 4 days);
        assertEq(reserve.recoveryFloorPriceUsd(), price);
        (uint256 startedAt, uint256 initial,,) = reserve.recovery();
        assertEq(startedAt, 0);
        assertEq(initial, 0);
        reserve.checkpointRecovery();
        (startedAt,,,) = reserve.recovery();
        assertEq(startedAt, block.timestamp);
    }

    function testStartsBeforeInsolvencyAndDoesNotRestartWhenCrashDeepens() public {
        oracle.setPrice(2_200 * WAD);
        reserve.checkpointRecovery();
        (uint256 startedAt, uint256 initial,,) = reserve.recovery();
        assertGt(reserve.equityUsd(), 0);
        vm.warp(block.timestamp + 12 hours);
        oracle.setPrice(1_000 * WAD);
        reserve.checkpointRecovery();
        (uint256 afterStart, uint256 afterInitial,,) = reserve.recovery();
        assertEq(afterStart, startedAt);
        assertEq(afterInitial, initial);
    }

    function testFloorHalvesAndInterpolatesWithoutStepAuction() public {
        _crash();
        uint256 initial = reserve.recoveryFloorPriceUsd();
        uint256 start = block.timestamp;
        vm.warp(start + 12 hours);
        assertEq(reserve.recoveryFloorPriceUsd(), Math.mulDiv(initial, 3, 4, Math.Rounding.Ceil));
        vm.warp(start + 1 days);
        assertEq(reserve.recoveryFloorPriceUsd(), initial >> 1);
        vm.warp(start + 2 days);
        assertEq(reserve.recoveryFloorPriceUsd(), initial >> 2);
    }

    function testLongDecayNeverMakesIssuanceFreeOrCancelsOldBalances() public {
        _crash();
        vm.warp(block.timestamp + 300 days);
        assertEq(reserve.recoveryFloorPriceUsd(), 1);
        vm.prank(BOB);
        uint256 infOut = reserve.recapitalize(WAD, 0, BOB);
        assertEq(infOut, 1_500 * WAD * WAD);
        assertEq(inf.balanceOf(ALICE), 300_000 * WAD);
        assertEq(address(reserve.inf()), address(inf));
        assertEq(reserve.infPriceUsd(), 0);
    }

    function testObservedFlashCrashAndReboundPreservesOldOwnership() public {
        _crash();
        vm.warp(block.timestamp + 6 hours);
        oracle.setPrice(3_000 * WAD);
        reserve.checkpointRecovery();
        (, uint256 initial,,) = reserve.recovery();
        assertEq(initial, 0);
        assertEq(inf.balanceOf(ALICE), inf.totalSupply());
        assertEq(reserve.recoveryFloorPriceUsd(), 0);
        assertEq(reserve.equityUsd(), 300_540 * WAD);
    }

    function testReboundBetweenTargetAndMaxResetsEpisodeBeforeNextCrash() public {
        reserve.setDebtRatios(5_000, 5_500, 6_500);
        assertGt(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertLe(reserve.debtRatioBps(), reserve.maxDebtRatioBps());

        _crash();
        (uint256 firstStart, uint256 firstFloor,,) = reserve.recovery();
        vm.warp(block.timestamp + 10 days);

        // The reserve has returned to the same healthy state as before the crash,
        // although its debt ratio is still above the withdrawal target.
        oracle.setPrice(3_000 * WAD);
        assertGt(reserve.infPriceUsd(), reserve.recoveryFloorPriceUsd());
        reserve.checkpointRecovery();
        (, uint256 endedFloor,,) = reserve.recovery();
        assertEq(endedFloor, 0);

        // A later crash must get a fresh floor, not the ten-day-old decayed one.
        oracle.setPrice(1_500 * WAD);
        reserve.checkpointRecovery();
        (uint256 secondStart, uint256 secondFloor,,) = reserve.recovery();
        assertGt(secondStart, firstStart);
        assertEq(secondFloor, firstFloor);
        assertEq(reserve.recoveryFloorPriceUsd(), firstFloor);
    }

    function testNewEpisodeStartsFreshAfterObservedRecovery() public {
        _crash();
        (uint256 oldStart, uint256 oldInitial,,) = reserve.recovery();
        vm.warp(block.timestamp + 10 days);
        oracle.setPrice(3_000 * WAD);
        reserve.checkpointRecovery();
        oracle.setPrice(1_500 * WAD);
        reserve.checkpointRecovery();
        (uint256 newStart, uint256 newInitial,,) = reserve.recovery();
        assertGt(newStart, oldStart);
        assertEq(newInitial, oldInitial);
        assertEq(reserve.recoveryFloorPriceUsd(), oldInitial);
    }

    function testUnobservedReboundDoesNotPretendToResetClock() public {
        _crash();
        uint256 initial = reserve.recoveryFloorPriceUsd();
        oracle.setPrice(3_000 * WAD);
        vm.warp(block.timestamp + 1 days);
        oracle.setPrice(1_500 * WAD);
        reserve.checkpointRecovery();
        assertEq(reserve.recoveryFloorPriceUsd(), initial >> 1);
    }

    function testFundingAcrossTargetDoesNotPrematurelyDropFloor() public {
        _crash();
        uint256 floor = reserve.recoveryFloorPriceUsd();
        vm.prank(BOB);
        reserve.fund(278 * WAD, 0, BOB);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertLt(reserve.infPriceUsd(), floor);
        assertEq(reserve.recoveryFloorPriceUsd(), floor);
        uint256 start = block.timestamp;
        vm.warp(start + 2 days);
        reserve.checkpointRecovery();
        assertEq(reserve.recoveryFloorPriceUsd(), 0);
        assertApproxEqAbs(reserve.fundingPriceUsd(), reserve.infPriceUsd(), 1);
    }

    function testSplitAtTargetBoundaryCannotBuyCheaperSecondTranche() public {
        _crash();
        uint256 snapshot = vm.snapshotState();
        vm.prank(BOB);
        uint256 whole = reserve.fund(350 * WAD, 0, BOB);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.prank(BOB);
        uint256 parts = reserve.fund(278 * WAD, 0, BOB);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        vm.prank(BOB);
        parts += reserve.fund(72 * WAD, 0, BOB);
        assertLe(parts, whole);
        assertApproxEqAbs(parts, whole, 1);
    }

    function testFlashCrashFundingDilutesButDoesNotExcludeOriginalHolderFromRebound() public {
        _crash();
        vm.prank(BOB);
        reserve.recapitalize(10 * WAD, 0, BOB);
        uint256 oldBalance = inf.balanceOf(ALICE);
        uint256 supply = inf.totalSupply();
        assertLt(oldBalance, supply);
        assertEq(reserve.equityUsd(), 0);
        oracle.setPrice(3_000 * WAD);
        reserve.checkpointRecovery();
        assertEq(inf.balanceOf(ALICE), oldBalance);
        assertEq(inf.totalSupply(), supply);
        uint256 oldClaim = Math.mulDiv(reserve.equityUsd(), oldBalance, supply);
        uint256 newClaim = Math.mulDiv(reserve.equityUsd(), inf.balanceOf(BOB), supply);
        assertGt(oldClaim, 0);
        assertGt(newClaim, 0);
        assertLe(oldClaim + newClaim, reserve.equityUsd());
    }

    function testPartialRecapitalizationDoesNotInventEquityOrWriteDownDebt() public {
        _crash();
        uint256 debt = reserve.debtUsd();
        vm.prank(BOB);
        reserve.recapitalize(WAD, 0, BOB);
        assertEq(reserve.debtUsd(), debt);
        assertEq(reserve.infPriceUsd(), 0);
        assertEq(reserve.maxDefundableUsd(), 0);
        assertGt(inf.balanceOf(BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.DebtRatioTooHigh.selector);
        reserve.mint(WAD, 0, BOB);
    }

    function testFloorCannotBeUsedForWithdrawal() public {
        _crash();
        vm.prank(ALICE);
        (uint256 series, uint256 epoch) = reserve.requestDefund(1_000 * WAD);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        assertGt(reserve.fundingPriceUsd(), 0);
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 out, uint256 refund) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(out, 0);
        assertEq(refund, 1_000 * WAD);
    }

    function testFundAndRecapitalizeHaveIdenticalQuotes() public {
        _crash();
        uint256 snapshot = vm.snapshotState();
        uint256 preview = reserve.previewFund(10 * WAD);
        vm.prank(BOB);
        uint256 viaFund = reserve.fund(10 * WAD, preview, BOB);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.prank(BOB);
        assertEq(reserve.recapitalize(10 * WAD, preview, BOB), viaFund);
    }

    function testRejectedFundingDoesNotPersistEpisodeOrMoveCollateral() public {
        oracle.setPrice(1_500 * WAD);
        uint256 balance = collateral.balanceOf(BOB);
        uint256 supply = inf.totalSupply();
        uint256 quote = reserve.previewFund(WAD);
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.fund(WAD, quote + 1, BOB);
        (, uint256 initial,,) = reserve.recovery();
        assertEq(initial, 0);
        assertEq(collateral.balanceOf(BOB), balance);
        assertEq(inf.totalSupply(), supply);
    }

    function testConfigChangesCannotRewriteActiveEpisode() public {
        _crash();
        (uint256 start, uint256 initial, uint256 period, uint256 exitRatio) = reserve.recovery();
        reserve.setRecoveryHalvingPeriod(7 days);
        reserve.setDebtRatios(4_000, 5_000, 6_000);
        vm.warp(block.timestamp + 1 days);
        reserve.checkpointRecovery();
        (uint256 newStart, uint256 newInitial, uint256 newPeriod, uint256 newExit) = reserve.recovery();
        assertEq(newStart, start);
        assertEq(newInitial, initial);
        assertEq(newPeriod, period);
        assertEq(newExit, exitRatio);
        assertEq(reserve.recoveryFloorPriceUsd(), initial >> 1);
        oracle.setPrice(4_000 * WAD);
        reserve.checkpointRecovery();
        oracle.setPrice(1_500 * WAD);
        reserve.checkpointRecovery();
        (,, newPeriod, newExit) = reserve.recovery();
        assertEq(newPeriod, 7 days);
        assertEq(newExit, 5_000);
    }

    function testHalvingConfigurationRequiresAuthorizerAndBounds() public {
        assertEq(reserve.recoveryHalvingPeriod(), 1 days);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        reserve.setRecoveryHalvingPeriod(2 days);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setRecoveryHalvingPeriod(1 hours - 1);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setRecoveryHalvingPeriod(30 days + 1);
        reserve.setRecoveryHalvingPeriod(1 hours);
        assertEq(reserve.recoveryHalvingPeriod(), 1 hours);
        reserve.setRecoveryHalvingPeriod(30 days);
        assertEq(reserve.recoveryHalvingPeriod(), 30 days);
    }

    function testRecoveryStartsAtTimestampZeroWithoutSentinelCollision() public {
        vm.warp(0);
        _crash();
        (uint256 start, uint256 initial,,) = reserve.recovery();
        assertEq(start, 0);
        assertGt(initial, 0);
        vm.warp(1 days);
        assertEq(reserve.recoveryFloorPriceUsd(), initial >> 1);
    }

    function testCheckpointAndFundingRequirePositivePrimary() public {
        _crash();
        oracle.setPrice(0);
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.checkpointRecovery();
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.previewFund(WAD);
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.fund(WAD, 0, BOB);
    }

    function testCapRemainsEnforcedDuringRecovery() public {
        _crash();
        vm.expectRevert(NaNReserve.DebtRatioTooLow.selector);
        reserve.previewFund(440 * WAD);
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.DebtRatioTooLow.selector);
        reserve.fund(440 * WAD, 0, BOB);
    }

    function testFuzzSplittingFundingCannotIncreaseIssuance(
        uint96 rawAmount,
        uint96 rawSplit,
        uint32 rawTime,
        uint16 rawPrice
    ) public {
        uint256 price = bound(uint256(rawPrice), 100, 2_999) * WAD;
        oracle.setPrice(price);
        reserve.checkpointRecovery();
        vm.warp(block.timestamp + bound(uint256(rawTime), 0, 300 days));
        uint256 maxAmount = Math.min(400 * WAD, reserve.maxFundableUsd() * WAD / price);
        uint256 amount = bound(uint256(rawAmount), 2e12, maxAmount);
        uint256 split = bound(uint256(rawSplit), 1e12, amount - 1e12);
        uint256 snapshot = vm.snapshotState();
        vm.prank(BOB);
        uint256 whole = reserve.fund(amount, 0, BOB);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.startPrank(BOB);
        uint256 parts = reserve.fund(split, 0, BOB);
        parts += reserve.fund(amount - split, 0, BOB);
        vm.stopPrank();
        assertLe(parts, whole);
        assertEq(inf.balanceOf(ALICE), 300_000 * WAD);
    }

    function testFuzzDecayIsMonotoneAndPositive(uint32 rawFirst, uint32 rawSecond) public {
        _crash();
        uint256 first = bound(uint256(rawFirst), 0, 1_000 days);
        uint256 second = bound(uint256(rawSecond), first, 1_001 days);
        uint256 start = block.timestamp;
        vm.warp(start + first);
        uint256 a = reserve.recoveryFloorPriceUsd();
        vm.warp(start + second);
        uint256 b = reserve.recoveryFloorPriceUsd();
        assertGe(a, b);
        assertGe(b, 1);
    }
}
