// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {NaNToken} from "../src/NaNToken.sol";

contract RedemptionFeeTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DEBT = 100_000 * WAD;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    NaNToken internal nan;

    function setUp() public {
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(4_000 * WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_500, 6_500, 0, 10);
        nan = reserve.nan();
        collateral.mint(ALICE, 100 * WAD);
        collateral.mint(BOB, 25 * WAD);
        vm.startPrank(ALICE);
        collateral.approve(address(reserve), 25 * WAD);
        reserve.fund(25 * WAD, 0, ALICE);
        vm.stopPrank();
        vm.startPrank(BOB);
        collateral.approve(address(reserve), 25 * WAD);
        reserve.mint(25 * WAD, DEBT, BOB);
        vm.stopPrank();
        oracle.setPrice(2_000 * WAD);
        assertEq(reserve.reserveUsd(), DEBT);
    }

    function _donate(uint256 amount) internal {
        vm.prank(ALICE);
        assertTrue(collateral.transfer(address(reserve), amount));
    }

    function _redeem(uint256 amount, uint256 expectedOut, uint256 expectedFee) internal returns (uint256 out) {
        uint256 balanceBefore = collateral.balanceOf(BOB);
        uint256 reserveBefore = reserve.reserveCollateral();
        uint256 debtBefore = reserve.debtUsd();
        // Recovery observations may emit before Redeemed; Foundry skips unrelated events.
        vm.expectEmit(true, true, false, true, address(reserve));
        emit NaNReserve.Redeemed(BOB, BOB, amount, expectedOut, expectedFee);
        vm.prank(BOB);
        out = reserve.redeem(amount, expectedOut, BOB);
        assertEq(out, expectedOut);
        assertEq(collateral.balanceOf(BOB) - balanceBefore, out);
        assertEq(reserve.reserveCollateral(), reserveBefore - out);
        assertEq(reserve.debtUsd(), debtBefore - amount);
    }

    function testOneWeiDonationCannotActivateFullRedemptionFee() public {
        uint256 snapshot = vm.snapshotState();
        uint256 atEquality = _redeem(10_000 * WAD, 5 * WAD, 0);
        vm.revertToState(snapshot);

        _donate(1);
        // One collateral wei is 2,000 USD base units. A 10% redemption
        // can retain at most 200 of those units as its explicit fee.
        uint256 afterDonation = _redeem(10_000 * WAD, 5 * WAD - 1, 200);
        assertEq(atEquality - afterDonation, 1);
    }

    function testBoundaryMatrixPartialAndFullRedemptions() public {
        uint256[3] memory fees = [uint256(0), 10, 1_000];
        for (uint256 i; i < fees.length; ++i) {
            for (int256 offset = -1; offset <= 1; ++offset) {
                for (uint256 full; full < 2; ++full) {
                    uint256 snapshot = vm.snapshotState();
                    reserve.setFees(0, fees[i]);
                    if (offset < 0) {
                        vm.prank(address(reserve));
                        assertTrue(collateral.transfer(ALICE, 1));
                    } else if (offset > 0) {
                        _donate(1);
                    }
                    uint256 amount = full == 1 ? DEBT : DEBT / 10;
                    uint256 backing = reserve.reserveCollateral();
                    uint256 expectedFee = offset > 0 && fees[i] != 0 ? amount * 2_000 / DEBT : 0;
                    uint256 gross = offset < 0 ? amount * (WAD - 1) / WAD : amount;
                    uint256 expectedOut = offset <= 0 && full == 1 ? backing : (gross - expectedFee) / 2_000;
                    _redeem(amount, expectedOut, expectedFee);
                    if (offset > 0) {
                        assertGe(reserve.equityUsd(), 2_000 + expectedFee);
                        assertLt(reserve.equityUsd(), 2_000 + expectedFee + 2_000);
                    } else if (full == 1) {
                        assertEq(reserve.reserveCollateral(), 0);
                    }
                    assertTrue(vm.revertToState(snapshot));
                }
            }
        }
    }

    function testFeeRampsWithEquityAndSaturatesAtConfiguredFee() public {
        uint256[5] memory equity = [uint256(0), 10 * WAD, 100 * WAD - 2_000, 100 * WAD, 1_000 * WAD];
        uint256[5] memory fee = [uint256(0), WAD, 10 * WAD - 200, 10 * WAD, 10 * WAD];
        for (uint256 i; i < equity.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _donate(equity[i] / 2_000);
            _redeem(10_000 * WAD, (10_000 * WAD - fee[i]) / 2_000, fee[i]);
            assertGe(reserve.equityUsd(), equity[i] + fee[i]);
            assertLt(reserve.equityUsd(), equity[i] + fee[i] + 2_000);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function testSlippageStillProtectsRedeemer() public {
        _donate(10 * WAD / 2_000);
        uint256 reserveBefore = reserve.reserveCollateral();
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.redeem(10_000 * WAD, 5 * WAD, BOB);
        assertEq(reserve.reserveCollateral(), reserveBefore);
        assertEq(reserve.debtUsd(), DEBT);
    }

    function testFullSolventRedemptionLeavesEquityAndFeeForInf() public {
        _donate(10 * WAD / 2_000);
        _redeem(DEBT, (DEBT - 10 * WAD) / 2_000, 10 * WAD);
        assertEq(reserve.debtUsd(), 0);
        assertEq(reserve.equityUsd(), 20 * WAD);
    }

    function testSplitRedemptionsRecomputeEquityIncludingRetainedFees() public {
        _donate(10 * WAD / 2_000);
        uint256 snapshot = vm.snapshotState();
        uint256 singleOut = _redeem(DEBT, (DEBT - 10 * WAD) / 2_000, 10 * WAD);
        assertTrue(vm.revertToState(snapshot));

        // The first half retains $5, raising equity from $10 to $15.
        uint256 splitOut = _redeem(DEBT / 2, (DEBT / 2 - 5 * WAD) / 2_000, 5 * WAD);
        splitOut += _redeem(DEBT / 2, (DEBT / 2 - 15 * WAD) / 2_000, 15 * WAD);
        assertEq((singleOut - splitOut) * 2_000, 10 * WAD);
        assertEq(reserve.equityUsd(), 30 * WAD);
    }

    function testRepeatedRedemptionsAfterDustDonationCannotEachChargeWholeEquity() public {
        _donate(1);
        // Keep every tranche in the equity-limited region, including the last.
        // A dust donation must not grow into the configured $100 aggregate fee.
        for (uint256 i; i < 10; ++i) {
            vm.prank(BOB);
            reserve.redeem(DEBT / 10, 0, BOB);
        }
        assertEq(reserve.debtUsd(), 0);
        assertLt(reserve.reserveCollateral(), 100);
    }

    function testUsdAndCollateralRoundingAtSubDollarPrice() public {
        oracle.setPrice(WAD / 4);
        deal(address(collateral), address(reserve), DEBT * 4);
        uint256 snapshot = vm.snapshotState();
        uint256 equalityOut = _redeem(DEBT / 10, DEBT / 10 * 4, 0);
        assertTrue(vm.revertToState(snapshot));

        _donate(1); // Below one USD base unit: reserve USD still equals debt.
        assertEq(reserve.reserveUsd(), DEBT);
        assertEq(_redeem(DEBT / 10, equalityOut, 0), equalityOut);
        // Donate enough to make the equity cap nonzero, but less than one bps.
        _donate(39);
        assertEq(reserve.equityUsd(), 10);
        // Remaining debt is $90,000; the next $10,000 burn has a 1-unit USD fee.
        _redeem(DEBT / 10, (DEBT / 10 - 1) * 4, 1);
        assertEq(reserve.equityUsd(), 11);
    }

    function testFullRedemptionAtFlooredEqualitySweepsFractionalUsdDust() public {
        uint256 price = WAD / 3;
        oracle.setPrice(price);
        uint256 backing = Math.mulDiv(DEBT, WAD, price, Math.Rounding.Ceil);
        deal(address(collateral), address(reserve), backing);
        assertEq(reserve.reserveUsd(), DEBT);
        assertGt(backing, Math.mulDiv(DEBT, WAD, price));
        _redeem(DEBT, backing, 0);
        assertEq(reserve.reserveCollateral(), 0);
    }

    function testEarmarkedWithdrawalsDoNotCountAsEquityOrRedemptionBacking() public {
        oracle.setPrice(4_000 * WAD);
        vm.startPrank(ALICE);
        reserve.inf().approve(address(reserve), 1_000 * WAD);
        (uint256 series, uint256 epoch) = reserve.requestDefund(1_000 * WAD);
        vm.stopPrank();
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        uint256 earmarked = reserve.claimableWithdrawalCollateral();
        assertGt(earmarked, 0);
        // Restore exact backing equality while keeping settled collateral in custody.
        oracle.setPrice(2_000 * WAD);
        _donate(earmarked);
        assertEq(reserve.reserveUsd(), DEBT);
        _donate(1);
        _redeem(DEBT, (DEBT - 2_000) / 2_000, 2_000);
        assertEq(reserve.reserveCollateral(), 2);
        assertEq(reserve.claimableWithdrawalCollateral(), earmarked);
        assertEq(collateral.balanceOf(address(reserve)), earmarked + 2);
        vm.prank(ALICE);
        (uint256 claimed,) = reserve.claimDefund(series, epoch, earmarked, ALICE);
        assertEq(claimed, earmarked);
        assertEq(reserve.reserveCollateral(), 2);
    }

    function testFuzzDonationOnlyIncreasesFeeByProportionalSurplus(uint96 rawAmount, uint96 rawDonation, uint16 rawFee)
        public
    {
        uint256 amount = bound(uint256(rawAmount), WAD, DEBT);
        uint256 donation = bound(uint256(rawDonation), 1, WAD);
        reserve.setFees(0, bound(uint256(rawFee), 0, 1_000));
        uint256 snapshot = vm.snapshotState();
        vm.prank(BOB);
        uint256 equalityOut = reserve.redeem(amount, 0, BOB);
        assertTrue(vm.revertToState(snapshot));
        _donate(donation);
        vm.prank(BOB);
        uint256 donatedOut = reserve.redeem(amount, 0, BOB);
        assertLe(donatedOut, equalityOut);
        // One additional collateral wei covers the USD-to-collateral floor.
        assertLe(equalityOut - donatedOut, Math.mulDiv(amount, donation, DEBT) + 1);
        assertEq(reserve.debtUsd(), DEBT - amount);
    }

    function testFuzzSplittingCannotIncreaseSolventPayoutBeyondRounding(
        uint96 rawAmount,
        uint96 rawFirst,
        uint96 rawDonation,
        uint16 rawFee
    ) public {
        uint256 amount = bound(uint256(rawAmount), 2 * WAD, DEBT);
        uint256 first = bound(uint256(rawFirst), WAD, amount - WAD);
        _donate(bound(uint256(rawDonation), 1, WAD));
        reserve.setFees(0, bound(uint256(rawFee), 0, 1_000));
        uint256 snapshot = vm.snapshotState();
        vm.prank(BOB);
        uint256 singleOut = reserve.redeem(amount, 0, BOB);
        assertTrue(vm.revertToState(snapshot));
        vm.startPrank(BOB);
        uint256 splitOut = reserve.redeem(first, 0, BOB);
        splitOut += reserve.redeem(amount - first, 0, BOB);
        vm.stopPrank();
        assertLe(splitOut, singleOut + 1);
        assertEq(reserve.debtUsd(), DEBT - amount);
    }
}
