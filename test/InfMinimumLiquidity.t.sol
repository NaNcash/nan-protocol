// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {INFToken} from "../src/INFToken.sol";

contract InfMinimumLiquidityTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal wstETH;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    INFToken internal inf;

    function setUp() public {
        wstETH = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        reserve = new NaNReserve(wstETH, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        inf = reserve.inf();
        wstETH.mint(ALICE, 2_000 * WAD);
        wstETH.mint(BOB, 2_000 * WAD);
        vm.startPrank(ALICE);
        wstETH.approve(address(reserve), type(uint256).max);
        inf.approve(address(reserve), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(BOB);
        wstETH.approve(address(reserve), type(uint256).max);
        inf.approve(address(reserve), type(uint256).max);
        vm.stopPrank();
    }

    function _requestAndSettle(uint256 amount) internal returns (uint256 series, uint256 epoch) {
        vm.prank(ALICE);
        (series, epoch) = reserve.requestDefund(amount);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
    }

    function testDonationAfterReducingSupplyCannotProfitFromLaterFunder() public {
        uint256 attackerBefore = wstETH.balanceOf(ALICE);
        // Use a small bootstrap that remains valid with minimum liquidity locked.
        vm.prank(ALICE);
        reserve.fund(1_000_000, 0, ALICE);
        (uint256 series, uint256 epoch) = _requestAndSettle(inf.balanceOf(ALICE) - 1);
        vm.prank(ALICE);
        reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(inf.totalSupply(), reserve.MINIMUM_INF_LIQUIDITY() + 1);

        vm.prank(ALICE);
        assertTrue(wstETH.transfer(address(reserve), WAD / 2));
        uint256 quote = reserve.previewFund(WAD);
        assertGe(quote, reserve.MINIMUM_INF_LIQUIDITY());
        vm.prank(BOB);
        assertEq(reserve.fund(WAD, quote, BOB), quote);

        (series, epoch) = _requestAndSettle(1);
        vm.prank(ALICE);
        reserve.claimDefund(series, epoch, 0, ALICE);

        assertLe(wstETH.balanceOf(ALICE), attackerBefore, "donation attack must not profit");
    }

    function testReportedOneWeiBootstrapIsRejected() public {
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.previewFund(1);
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.fund(1, 0, ALICE);
        assertEq(inf.totalSupply(), 0);
        assertEq(reserve.reserveCollateral(), 0);
    }

    function testBootstrapAtOrBelowMinimumRevertsWithoutPullingCollateral() public {
        oracle.setPrice(WAD);
        uint256 minimum = reserve.MINIMUM_INF_LIQUIDITY();
        uint256 beforeBalance = wstETH.balanceOf(ALICE);
        for (uint256 amount = minimum - 1; amount <= minimum; ++amount) {
            vm.expectRevert(NaNReserve.Slippage.selector);
            reserve.previewFund(amount);
            vm.prank(ALICE);
            vm.expectRevert(NaNReserve.Slippage.selector);
            reserve.fund(amount, 0, ALICE);
        }
        assertEq(wstETH.balanceOf(ALICE), beforeBalance);
        assertEq(inf.totalSupply(), 0);
        assertEq(inf.balanceOf(address(reserve)), 0);
    }

    function testBootstrapQuoteSlippageAndEventUseNetRecipientOutput() public {
        uint256 quote = reserve.previewFund(WAD);
        assertEq(quote, 3_000 * WAD - reserve.MINIMUM_INF_LIQUIDITY());
        uint256 beforeBalance = wstETH.balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.fund(WAD, quote + 1, BOB);
        assertEq(inf.totalSupply(), 0);
        assertEq(wstETH.balanceOf(ALICE), beforeBalance);

        vm.expectEmit(true, true, false, true, address(reserve));
        emit NaNReserve.Funded(ALICE, BOB, WAD, quote);
        vm.prank(ALICE);
        assertEq(reserve.fund(WAD, quote, BOB), quote);
        assertEq(inf.balanceOf(BOB), quote);
        assertEq(inf.totalSupply(), 3_000 * WAD);
        assertEq(inf.balanceOf(address(reserve)), reserve.MINIMUM_INF_LIQUIDITY());
        assertEq(reserve.infPriceUsd(), WAD);

        vm.prank(BOB);
        assertEq(reserve.fund(WAD, 3_000 * WAD, BOB), 3_000 * WAD);
        assertEq(inf.balanceOf(address(reserve)), reserve.MINIMUM_INF_LIQUIDITY());
    }

    function testFundingAfterAllUserSharesExitUsesNavWithoutLockingAgain() public {
        oracle.setPrice(WAD);
        uint256 minimum = reserve.MINIMUM_INF_LIQUIDITY();
        assertEq(reserve.previewFund(minimum + 1), 1);
        vm.prank(ALICE);
        assertEq(reserve.fund(minimum + 1, 1, ALICE), 1);
        (uint256 series, uint256 epoch) = _requestAndSettle(1);
        vm.prank(ALICE);
        (uint256 out, uint256 refund) = reserve.claimDefund(series, epoch, 1, ALICE);
        assertEq(out, 1);
        assertEq(refund, 0);
        assertEq(inf.totalSupply(), minimum);
        assertEq(reserve.reserveCollateral(), minimum);

        oracle.setPrice(3_000 * WAD);
        assertEq(reserve.previewFund(WAD), WAD);
        vm.prank(BOB);
        assertEq(reserve.fund(WAD, WAD, BOB), WAD);
        assertEq(inf.totalSupply(), minimum + WAD);
        assertEq(inf.balanceOf(address(reserve)), minimum);
    }

    function testMultipleDebtFreeCohortsCannotBurnMinimumLiquidity() public {
        vm.prank(ALICE);
        reserve.fund(WAD, 0, ALICE);
        uint256 bobInf = inf.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        assertTrue(inf.transfer(BOB, bobInf));
        uint256 aliceInf = inf.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 series, uint256 aliceEpoch) = reserve.requestDefund(aliceInf);
        vm.warp(block.timestamp + reserve.infWithdrawalEpoch());
        vm.prank(BOB);
        (, uint256 bobEpoch) = reserve.requestDefund(bobInf);

        vm.warp(reserve.withdrawalMaturity(series, aliceEpoch));
        reserve.settleDefundEpoch(series, aliceEpoch);
        vm.warp(reserve.withdrawalMaturity(series, bobEpoch));
        reserve.settleDefundEpoch(series, bobEpoch);
        assertEq(inf.totalSupply(), reserve.MINIMUM_INF_LIQUIDITY());
        assertEq(inf.balanceOf(address(reserve)), reserve.MINIMUM_INF_LIQUIDITY());
        assertGt(reserve.reserveCollateral(), 0);

        vm.prank(BOB);
        reserve.claimDefund(series, bobEpoch, 0, BOB);
        vm.prank(ALICE);
        reserve.claimDefund(series, aliceEpoch, 0, ALICE);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        assertEq(inf.balanceOf(address(reserve)), reserve.MINIMUM_INF_LIQUIDITY());
    }

    function testFuzzDonationAfterPartialExitCannotProfit(
        uint96 rawBootstrap,
        uint96 rawRetained,
        uint96 rawDonation,
        uint96 rawVictimDeposit
    ) public {
        uint256 bootstrap = bound(uint256(rawBootstrap), reserve.MINIMUM_INF_LIQUIDITY() / 3_000 + 1, WAD);
        uint256 donation = bound(uint256(rawDonation), 0, 100 * WAD);
        uint256 victimDeposit = bound(uint256(rawVictimDeposit), 1e12, 100 * WAD);
        uint256 attackerBefore = wstETH.balanceOf(ALICE);
        vm.prank(ALICE);
        reserve.fund(bootstrap, 0, ALICE);
        uint256 retained = bound(uint256(rawRetained), 1, inf.balanceOf(ALICE));
        uint256 exitInf = inf.balanceOf(ALICE) - retained;
        if (exitInf != 0) {
            (uint256 series, uint256 epoch) = _requestAndSettle(exitInf);
            vm.prank(ALICE);
            reserve.claimDefund(series, epoch, 0, ALICE);
        }
        vm.prank(ALICE);
        assertTrue(wstETH.transfer(address(reserve), donation));
        uint256 quote = reserve.previewFund(victimDeposit);
        assertGt(quote, 0);
        vm.prank(BOB);
        assertEq(reserve.fund(victimDeposit, quote, BOB), quote);
        (uint256 exitSeries, uint256 exitEpoch) = _requestAndSettle(retained);
        vm.prank(ALICE);
        reserve.claimDefund(exitSeries, exitEpoch, 0, ALICE);

        assertLe(wstETH.balanceOf(ALICE), attackerBefore, "donation attack must not profit");
        assertGe(inf.totalSupply(), reserve.MINIMUM_INF_LIQUIDITY());
        assertEq(inf.balanceOf(address(reserve)), reserve.MINIMUM_INF_LIQUIDITY());
    }
}
