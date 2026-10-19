// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract WithdrawalPriorityTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant REQUEST = 40 * WAD;
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0xCA11);
    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    uint256 internal firstEpoch;
    uint256 internal secondEpoch;

    function setUp() public {
        vm.warp(10 days);
        collateral = new MockERC20("Collateral", "COL");
        oracle = new MockOracle(WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_500, 6_500, 0, 0);
        collateral.mint(address(this), 200 * WAD);
        collateral.approve(address(reserve), 200 * WAD);
        reserve.fund(100 * WAD, 0, address(this));
        reserve.mint(100 * WAD, 0, address(this));
        reserve.inf().approve(address(reserve), REQUEST);
        assertTrue(reserve.inf().transfer(BOB, REQUEST));
        vm.startPrank(BOB);
        reserve.inf().approve(address(reserve), REQUEST);
        vm.stopPrank();

        reserve.setInfWithdrawalEpoch(1 hours);
        (, uint256 boundary) = reserve.currentWithdrawalEpoch();
        vm.warp(boundary);
        (, firstEpoch) = reserve.requestDefund(REQUEST);
    }

    function _requestSecond(bool shortenDelay) internal {
        (, uint256 boundary) = reserve.currentWithdrawalEpoch();
        vm.warp(boundary);
        if (shortenDelay) reserve.setInfWithdrawalDelay(1 days);
        vm.prank(BOB);
        (, secondEpoch) = reserve.requestDefund(REQUEST);
        assertEq(secondEpoch, firstEpoch + 1);
    }

    function _assertFirstSuccessfulSettlementWins(bool laterFirst) internal {
        _requestSecond(false);
        assertLt(reserve.withdrawalMaturity(1, firstEpoch), reserve.withdrawalMaturity(1, secondEpoch));
        assertLt(reserve.withdrawalMaturity(1, secondEpoch), reserve.withdrawalExpiry(1, firstEpoch));
        vm.warp(reserve.withdrawalMaturity(1, secondEpoch));
        uint256 winner = laterFirst ? secondEpoch : firstEpoch;
        uint256 loser = laterFirst ? firstEpoch : secondEpoch;
        uint256 supply = reserve.inf().totalSupply();

        vm.prank(KEEPER);
        reserve.settleDefundEpoch(1, winner);
        (,, uint256 filled, uint256 payout, bool settled,) = reserve.withdrawalEpochs(1, winner);
        assertGt(filled, 0);
        assertLt(filled, REQUEST);
        assertFalse(settled);
        assertEq(reserve.maxDefundableUsd(), 0);
        vm.prank(KEEPER);
        vm.expectRevert(NaNReserve.NoWithdrawalCapacity.selector);
        reserve.settleDefundEpoch(1, loser);
        (,, uint256 loserFilled, uint256 loserPayout, bool loserSettled,) = reserve.withdrawalEpochs(1, loser);
        assertEq(loserFilled, 0);
        assertEq(loserPayout, 0);
        assertFalse(loserSettled);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertEq(reserve.inf().totalSupply() + filled, supply);
        assertEq(reserve.claimableWithdrawalCollateral(), payout);

        // Expiry releases both cohorts without requiring any earlier settlement
        // or a working oracle. The loser recovers every locked share.
        vm.warp(reserve.withdrawalExpiry(1, secondEpoch));
        oracle.setPrice(0);
        vm.startPrank(KEEPER);
        reserve.expireDefundEpoch(1, firstEpoch);
        reserve.expireDefundEpoch(1, secondEpoch);
        vm.stopPrank();
        (uint256 firstOut, uint256 firstRefund) = reserve.claimDefund(1, firstEpoch, 0, address(this));
        vm.prank(BOB);
        (uint256 secondOut, uint256 secondRefund) = reserve.claimDefund(1, secondEpoch, 0, BOB);
        assertEq(firstOut + secondOut, payout);
        assertEq(firstRefund + secondRefund + filled, 2 * REQUEST);
        assertEq(laterFirst ? firstOut : secondOut, 0);
        assertEq(laterFirst ? firstRefund : secondRefund, REQUEST);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        assertEq(reserve.inf().balanceOf(address(reserve)), 0);
    }

    function testLaterCohortCanConsumeSharedCapacityBeforeEarlierCohort() public {
        _assertFirstSuccessfulSettlementWins(true);
    }

    function testEarlierCohortCanConsumeSharedCapacityBeforeLaterCohort() public {
        _assertFirstSuccessfulSettlementWins(false);
    }

    function testShortenedDelayCanInvertMaturityWithoutChangingExistingCohort() public {
        uint256 firstMaturity = reserve.withdrawalMaturity(1, firstEpoch);
        uint256 firstExpiry = reserve.withdrawalExpiry(1, firstEpoch);
        _requestSecond(true);
        uint256 secondMaturity = reserve.withdrawalMaturity(1, secondEpoch);
        assertLt(secondMaturity, firstMaturity);
        assertEq(reserve.withdrawalMaturity(1, firstEpoch), firstMaturity);
        assertEq(reserve.withdrawalExpiry(1, firstEpoch), firstExpiry);
        vm.warp(secondMaturity);
        vm.expectRevert(NaNReserve.WithdrawalNotReady.selector);
        reserve.settleDefundEpoch(1, firstEpoch);
        vm.prank(KEEPER);
        reserve.settleDefundEpoch(1, secondEpoch);
        assertEq(reserve.maxDefundableUsd(), 0);

        vm.warp(firstMaturity);
        vm.expectRevert(NaNReserve.NoWithdrawalCapacity.selector);
        reserve.settleDefundEpoch(1, firstEpoch);
        vm.warp(firstExpiry);
        reserve.expireDefundEpoch(1, firstEpoch);
        (uint256 payout, uint256 refund) = reserve.claimDefund(1, firstEpoch, 0, address(this));
        assertEq(payout, 0);
        assertEq(refund, REQUEST);
    }

    function testEmptyExpiredAndZeroCapacityCohortsCannotBlockLaterSettlement() public {
        _requestSecond(false);
        vm.warp(reserve.withdrawalMaturity(1, secondEpoch));
        oracle.setPrice(WAD / 2);
        vm.expectRevert(NaNReserve.NoWithdrawalCapacity.selector);
        reserve.settleDefundEpoch(1, firstEpoch);
        vm.warp(reserve.withdrawalExpiry(1, firstEpoch));
        reserve.expireDefundEpoch(1, firstEpoch);
        vm.expectRevert(NaNReserve.NoWithdrawalRequest.selector);
        reserve.settleDefundEpoch(1, firstEpoch - 1);
        vm.expectRevert(NaNReserve.WithdrawalAlreadySettled.selector);
        reserve.settleDefundEpoch(1, firstEpoch);

        oracle.setPrice(WAD);
        vm.prank(KEEPER);
        reserve.settleDefundEpoch(1, secondEpoch);
        (,, uint256 filled, uint256 payout,,) = reserve.withdrawalEpochs(1, secondEpoch);
        assertGt(filled, 0);
        assertGt(payout, 0);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
    }
}
