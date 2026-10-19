// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {INFToken} from "../src/INFToken.sol";

contract InfFinalExitTest is Test {
    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    INFToken internal inf;
    address internal constant SECOND = address(0xB0B);

    struct DebtExit {
        uint256 debt;
        uint256 backing;
        uint256 half;
        uint256 firstEpoch;
        uint256 secondEpoch;
        uint256 secondPayout;
    }

    function setUp() public {
        vm.warp(10 days);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000e18);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_500, 6_500, 0, 0);
        inf = reserve.inf();
        collateral.mint(address(this), 100e18);
        collateral.mint(SECOND, 100e18);
        collateral.approve(address(reserve), type(uint256).max);
        inf.approve(address(reserve), type(uint256).max);
        vm.prank(SECOND);
        inf.approve(address(reserve), type(uint256).max);
        vm.prank(SECOND);
        collateral.approve(address(reserve), type(uint256).max);
    }

    function _request(address account, uint256 amount) internal returns (uint256 epoch) {
        vm.prank(account);
        (, epoch) = reserve.requestDefund(amount);
    }

    function _settle(uint256 epoch) internal {
        vm.warp(reserve.withdrawalMaturity(1, epoch));
        reserve.settleDefundEpoch(1, epoch);
    }

    function _reachMinimum() internal {
        _leaveSupply(reserve.MIN_INF_SUPPLY());
    }

    function _leaveSupply(uint256 remaining) internal {
        uint256 supply = reserve.fund(1_000_000, 0, address(this));
        uint256 epoch = _request(address(this), supply - remaining);
        _settle(epoch);
        reserve.claimDefund(1, epoch, 0, address(this));
        assertEq(inf.totalSupply(), remaining);
    }

    function testFragmentedMinimumSupplyExitsAcrossDistinctEpochs() public {
        _reachMinimum();
        assertTrue(collateral.transfer(address(reserve), 6e18));
        uint256 backing = reserve.reserveCollateral();
        uint256 half = inf.totalSupply() / 2;
        assertTrue(inf.transfer(SECOND, half));
        uint256 firstEpoch = _request(address(this), half);
        (, uint256 closesAt) = reserve.currentWithdrawalEpoch();
        vm.warp(closesAt);
        uint256 secondEpoch = _request(SECOND, half);
        assertGt(secondEpoch, firstEpoch);

        // These unrelated holders never combine balances or requests. With no
        // debt they can settle in kind, including during a primary outage.
        oracle.setPrice(0);
        _settle(firstEpoch);
        assertEq(inf.totalSupply(), half);
        _settle(secondEpoch);
        assertEq(inf.totalSupply(), 0);
        assertEq(reserve.reserveCollateral(), 0);
        assertEq(reserve.claimableWithdrawalCollateral(), backing);

        // Reverse the claim order; the final settlement must exclude collateral
        // already earmarked for the earlier epoch.
        vm.prank(SECOND);
        (uint256 secondOut, uint256 secondRefund) = reserve.claimDefund(1, secondEpoch, 0, SECOND);
        (uint256 firstOut, uint256 firstRefund) = reserve.claimDefund(1, firstEpoch, 0, address(this));
        assertGt(firstOut, 3e18);
        assertEq(firstOut + secondOut, backing);
        assertEq(firstRefund + secondRefund, 0);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(inf.balanceOf(address(reserve)), 0);
    }

    function testExpiredFragmentCanRequeueAndExitWithoutOtherHolder() public {
        _reachMinimum();
        assertTrue(collateral.transfer(address(reserve), 6e18));
        uint256 half = inf.totalSupply() / 2;
        assertTrue(inf.transfer(SECOND, half));
        uint256 expiredEpoch = _request(address(this), half);
        vm.warp(reserve.withdrawalExpiry(1, expiredEpoch));
        reserve.expireDefundEpoch(1, expiredEpoch);
        (uint256 expiredOut, uint256 refund) = reserve.claimDefund(1, expiredEpoch, 0, address(this));
        assertEq(expiredOut, 0);
        assertEq(refund, half);

        // SECOND never queues or transfers its residual balance.
        uint256 nextEpoch = _request(address(this), refund);
        _settle(nextEpoch);
        (uint256 out, uint256 nextRefund) = reserve.claimDefund(1, nextEpoch, 0, address(this));
        assertGt(out, 3e18);
        assertEq(nextRefund, 0);
        assertEq(inf.totalSupply(), half);
        assertEq(inf.balanceOf(SECOND), half);
    }

    function testDebtBearingFragmentsRespectTargetUntilSeniorRedemption() public {
        _reachMinimum();
        assertTrue(collateral.transfer(address(reserve), 1e18));
        reserve.mint(0.25e18, 0, address(this));
        DebtExit memory state;
        state.debt = reserve.debtUsd();
        state.backing = reserve.reserveCollateral();
        state.half = inf.totalSupply() / 2;
        assertTrue(inf.transfer(SECOND, state.half));
        state.firstEpoch = _request(address(this), state.half);
        (, uint256 closesAt) = reserve.currentWithdrawalEpoch();
        vm.warp(closesAt);
        state.secondEpoch = _request(SECOND, state.half);
        _settle(state.firstEpoch);
        assertEq(inf.totalSupply(), state.half);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());

        {
            _settle(state.secondEpoch);
            (,, uint256 filled, uint256 secondPayout, bool settled,) = reserve.withdrawalEpochs(1, state.secondEpoch);
            state.secondPayout = secondPayout;
            assertGt(filled, 0);
            assertLt(filled, state.half);
            assertFalse(settled);
            assertGt(inf.totalSupply(), 0);
            assertLt(inf.totalSupply(), state.half);
            assertEq(reserve.debtUsd(), state.debt);
            assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
            uint256 minimumUsd =
                Math.mulDiv(state.debt, reserve.BPS(), reserve.targetDebtRatioBps(), Math.Rounding.Ceil);
            assertGe(reserve.reserveUsd(), minimumUsd);
        }

        vm.expectRevert(NaNReserve.NoWithdrawalCapacity.selector);
        reserve.settleDefundEpoch(1, state.secondEpoch);
        oracle.setPrice(0);
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.settleDefundEpoch(1, state.secondEpoch);
        assertEq(reserve.debtUsd(), state.debt);
        oracle.setPrice(3_000e18);
        uint256 seniorOut = reserve.redeem(state.debt, 0, address(this));
        // Retrying the original cohort after debt is removed needs no new wait.
        reserve.settleDefundEpoch(1, state.secondEpoch);
        {
            (,, uint256 finalFilled, uint256 finalPayout, bool finalSettled,) =
                reserve.withdrawalEpochs(1, state.secondEpoch);
            assertTrue(finalSettled);
            assertEq(finalFilled, state.half);
            assertGt(finalPayout, state.secondPayout);
        }
        assertEq(inf.totalSupply(), 0);
        vm.prank(SECOND);
        (uint256 secondOut, uint256 secondRefund) = reserve.claimDefund(1, state.secondEpoch, 0, SECOND);
        (uint256 firstOut, uint256 firstRefund) = reserve.claimDefund(1, state.firstEpoch, 0, address(this));
        assertEq(firstRefund + secondRefund, 0);
        assertEq(firstOut + secondOut + seniorOut, state.backing);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(inf.balanceOf(address(reserve)), 0);
    }

    function testSubminimumSupplyBlocksNanMintUntilPreciseFundingRestoresMinimum() public {
        _leaveSupply(1);
        uint256 backing = reserve.reserveCollateral();
        assertEq(backing, 1);
        vm.expectRevert(NaNReserve.NoJuniorCapital.selector);
        reserve.mint(1, 0, address(this));
        assertEq(reserve.reserveCollateral(), backing);
        assertEq(reserve.debtUsd(), 0);
        uint256 issued = reserve.fund(reserve.MIN_INF_SUPPLY(), 0, address(this));
        assertEq(issued, reserve.MIN_INF_SUPPLY());
        assertEq(inf.totalSupply(), 1 + issued);
        assertEq(reserve.mint(1, 0, address(this)), 3_000);
    }

    function testReportedDonationAttackAtOneRemainingShareRejectsVictimDeposit() public {
        _leaveSupply(1);
        assertEq(reserve.reserveCollateral(), 1);
        assertTrue(collateral.transfer(address(reserve), 1e18));
        uint256 victimBalance = collateral.balanceOf(SECOND);
        vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
        reserve.previewFund(1.999e18);
        vm.prank(SECOND);
        vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
        reserve.fund(1.999e18, 0, SECOND);
        assertEq(collateral.balanceOf(SECOND), victimBalance);
        assertEq(inf.totalSupply(), 1);
        // The final share can recover its own donation without trapping collateral.
        uint256 epoch = _request(address(this), 1);
        _settle(epoch);
        (uint256 out, uint256 refund) = reserve.claimDefund(1, epoch, 0, address(this));
        assertEq(out, 1e18 + 1);
        assertEq(refund, 0);
        assertEq(inf.totalSupply(), 0);
    }

    function testZeroCollateralFragmentStillCannotBurnForNothing() public {
        _leaveSupply(2);
        assertEq(reserve.reserveCollateral(), 1);
        uint256 epoch = _request(address(this), 1);
        vm.warp(reserve.withdrawalMaturity(1, epoch));
        vm.expectRevert(NaNReserve.NoWithdrawalCapacity.selector);
        reserve.settleDefundEpoch(1, epoch);
        assertEq(inf.totalSupply(), 2);
        assertEq(reserve.reserveCollateral(), 1);
    }

    function testFuzzLowSupplyDonationPreservesDepositPrecision(uint64 rawSupply, uint96 rawDonation, uint96 rawDeposit)
        public
    {
        uint256 supply = bound(uint256(rawSupply), 1, reserve.MIN_INF_SUPPLY() - 1);
        _leaveSupply(supply);
        uint256 donation = bound(uint256(rawDonation), 0, 50e18);
        assertTrue(collateral.transfer(address(reserve), donation));
        uint256 backing = reserve.reserveCollateral();
        uint256 deposit = bound(uint256(rawDeposit), 1, 100e18);
        uint256 exactFloor = Math.mulDiv(deposit, supply, backing);
        uint256 victimBalance = collateral.balanceOf(SECOND);
        if (exactFloor < reserve.MIN_INF_SUPPLY()) {
            vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
            reserve.previewFund(deposit);
            vm.prank(SECOND);
            vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
            reserve.fund(deposit, 0, SECOND);
            assertEq(collateral.balanceOf(SECOND), victimBalance);
            assertEq(inf.totalSupply(), supply);
            assertEq(reserve.reserveCollateral(), backing);
            return;
        }
        assertEq(reserve.previewFund(deposit), exactFloor);
        vm.prank(SECOND);
        uint256 minted = reserve.fund(deposit, 0, SECOND);
        assertEq(minted, exactFloor);
        assertGe(minted, reserve.MIN_INF_SUPPLY());
        assertGe(inf.totalSupply(), reserve.MIN_INF_SUPPLY());
        uint256 claim = Math.mulDiv(minted, reserve.reserveCollateral(), inf.totalSupply());
        assertLe(deposit - claim, Math.ceilDiv(deposit, reserve.MIN_INF_SUPPLY()) + 1);
        assertEq(collateral.balanceOf(SECOND), victimBalance - deposit);
    }

    function testFuzzFragmentedFinalClaimsConserveAcrossEpochs(uint96 rawSplit, bool settleReverse, bool claimReverse)
        public
    {
        _reachMinimum();
        assertTrue(collateral.transfer(address(reserve), 6e18));
        reserve.setInfWithdrawalEpoch(1 hours);
        uint256 supply = inf.totalSupply();
        uint256 firstAmount = bound(uint256(rawSplit), 1, supply - 1);
        assertTrue(inf.transfer(SECOND, supply - firstAmount));
        uint256 firstEpoch = _request(address(this), firstAmount);
        (, uint256 closesAt) = reserve.currentWithdrawalEpoch();
        vm.warp(closesAt);
        uint256 secondEpoch = _request(SECOND, supply - firstAmount);
        vm.warp(reserve.withdrawalMaturity(1, secondEpoch));
        uint256 backing = reserve.reserveCollateral();
        oracle.setPrice(0);
        reserve.settleDefundEpoch(1, settleReverse ? secondEpoch : firstEpoch);
        reserve.settleDefundEpoch(1, settleReverse ? firstEpoch : secondEpoch);
        assertEq(inf.totalSupply(), 0);
        assertEq(reserve.reserveCollateral(), 0);
        assertEq(reserve.claimableWithdrawalCollateral(), backing);
        uint256 totalOut;
        for (uint256 i; i < 2; ++i) {
            bool isSecond = (i == 0) == claimReverse;
            address account = isSecond ? SECOND : address(this);
            vm.prank(account);
            (uint256 out, uint256 refund) = reserve.claimDefund(1, isSecond ? secondEpoch : firstEpoch, 0, account);
            assertEq(refund, 0);
            assertGt(out, 0);
            totalOut += out;
            assertEq(reserve.claimableWithdrawalCollateral(), backing - totalOut);
        }
        assertEq(totalOut, backing);
        assertEq(collateral.balanceOf(address(reserve)), 0);
        assertEq(inf.balanceOf(address(reserve)), 0);
    }
}
