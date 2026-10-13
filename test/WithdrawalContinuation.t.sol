// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";

contract WithdrawalContinuationTest is Test {
    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    address internal constant ATTACKER = address(0xBAD);
    address internal constant SECOND = address(0xB0B);
    uint256 internal series;
    uint256 internal epoch;

    function setUp() public {
        vm.warp(10 days);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000e18);
        reserve = new NaNReserve(collateral, oracle, address(this), 3_000, 5_500, 6_500, 10, 10);
        collateral.mint(address(this), 100e18);
        collateral.mint(ATTACKER, 100e18);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(ATTACKER);
        collateral.approve(address(reserve), type(uint256).max);
        reserve.fund(50e18, 0, address(this));
        reserve.mint(50e18, 0, address(this));
        reserve.inf().approve(address(reserve), type(uint256).max);
        (series, epoch) = reserve.requestDefund(60_000e18);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
    }

    function _mintThenSettle(uint256 amount, bool zeroFill) internal {
        vm.prank(ATTACKER);
        uint256 minted = reserve.mint(amount, 0, ATTACKER);
        if (zeroFill) vm.expectRevert(NaNReserve.NoWithdrawalCapacity.selector);
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ATTACKER);
        reserve.redeem(minted, 0, ATTACKER);
    }

    function testAtomicMintSettleRedeemCannotConsumeMaturityAtZeroFill() public {
        uint256 maturity = reserve.withdrawalMaturity(series, epoch);
        _mintThenSettle(20e18, true);
        (,, uint256 filled,, bool settled,) = reserve.withdrawalEpochs(series, epoch);
        assertEq(filled, 0);
        assertFalse(settled);
        assertEq(reserve.withdrawalMaturity(series, epoch), maturity);
        assertGt(reserve.maxDefundableUsd(), 27_000e18);
        reserve.settleDefundEpoch(series, epoch);
        (,, filled,, settled,) = reserve.withdrawalEpochs(series, epoch);
        assertGt(filled, 0);
        assertFalse(settled);
    }

    function testTinyPartialFillCanContinueWithoutAnotherWithdrawalDelay() public {
        uint256 numerator = reserve.targetDebtRatioBps() * reserve.reserveUsd() - reserve.BPS() * reserve.debtUsd();
        uint256 denominator = 3_000e18 * (reserve.BPS() - reserve.mintFeeBps() - reserve.targetDebtRatioBps());
        uint256 amount = Math.mulDiv(numerator, 1e18, denominator) - 1e12;
        _mintThenSettle(amount, false);
        (,, uint256 firstFilled, uint256 firstOut, bool settled,) = reserve.withdrawalEpochs(series, epoch);
        assertGt(firstFilled, 0);
        assertLt(firstFilled, 1e18);
        assertFalse(settled);
        uint256 maturity = reserve.withdrawalMaturity(series, epoch);
        vm.expectRevert(NaNReserve.WithdrawalNotSettled.selector);
        reserve.claimDefund(series, epoch, 0, address(this));
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 secondFilled, uint256 secondOut,,) = reserve.withdrawalEpochs(series, epoch);
        assertGt(secondFilled, firstFilled);
        assertGt(secondOut, firstOut);
        assertEq(reserve.withdrawalMaturity(series, epoch), maturity);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());

        // A rebound adds capacity within the same window and completes the original request.
        oracle.setPrice(4_000e18);
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filled, uint256 payout, bool finalSettled,) = reserve.withdrawalEpochs(series, epoch);
        assertTrue(finalSettled);
        assertEq(filled, 60_000e18);
        (uint256 claimed, uint256 refund) = reserve.claimDefund(series, epoch, payout, address(this));
        assertEq(claimed, payout);
        assertEq(refund, 0);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
    }

    function testExpiryPreservesPartialCollateralAndRefundsRemainingInfWithoutOracle() public {
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filled, uint256 payout, bool settled,) = reserve.withdrawalEpochs(series, epoch);
        assertFalse(settled);
        uint256 supply = reserve.inf().totalSupply();
        uint256 backing = reserve.reserveCollateral();
        oracle.setPrice(0);
        vm.warp(reserve.withdrawalExpiry(series, epoch));
        reserve.expireDefundEpoch(series, epoch);
        (uint256 claimed, uint256 refund) = reserve.claimDefund(series, epoch, payout, address(this));
        assertEq(claimed, payout);
        assertEq(refund + filled, 60_000e18);
        assertEq(reserve.inf().totalSupply(), supply);
        assertEq(reserve.reserveCollateral(), backing);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        vm.expectRevert(NaNReserve.WithdrawalAlreadySettled.selector);
        reserve.settleDefundEpoch(series, epoch);
    }

    function testFuzzMultipleFillsConserveCohortClaims(uint96 rawPrice, bool reverse) public {
        vm.warp(10 days);
        reserve.inf().transfer(SECOND, 30_000e18);
        vm.startPrank(SECOND);
        reserve.inf().approve(address(reserve), 30_000e18);
        reserve.requestDefund(30_000e18);
        vm.stopPrank();
        uint256 originalSupply = reserve.inf().totalSupply();
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        oracle.setPrice(bound(uint256(rawPrice), 3_001e18, 6_000e18));
        reserve.settleDefundEpoch(series, epoch);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        (,, uint256 filled, uint256 payout, bool settled,) = reserve.withdrawalEpochs(series, epoch);
        if (!settled) {
            vm.warp(reserve.withdrawalExpiry(series, epoch));
            oracle.setPrice(0);
            reserve.expireDefundEpoch(series, epoch);
        }
        address first = reverse ? SECOND : address(this);
        address second = reverse ? address(this) : SECOND;
        vm.prank(first);
        (uint256 firstOut, uint256 firstRefund) = reserve.claimDefund(series, epoch, 0, first);
        vm.prank(second);
        (uint256 secondOut, uint256 secondRefund) = reserve.claimDefund(series, epoch, 0, second);
        assertEq(firstOut + secondOut, payout);
        assertEq(firstRefund + secondRefund + filled, 90_000e18);
        assertEq(reserve.inf().totalSupply() + filled, originalSupply);
        assertEq(reserve.inf().balanceOf(address(reserve)), 0);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        uint256 smallOut = reverse ? firstOut : secondOut;
        uint256 largeOut = reverse ? secondOut : firstOut;
        // Filled-INF interval rounding precedes collateral rounding; doubling the smaller claim
        // also doubles its one-wei collateral error.
        assertApproxEqAbs(largeOut, 2 * smallOut, 4);
    }
}
