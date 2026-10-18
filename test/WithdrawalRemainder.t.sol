// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";

contract WithdrawalRemainderTest is Test {
    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    address internal constant SECOND = address(0xB0B);

    struct Snapshot {
        uint256 supply;
        uint256 backing;
        uint256 debt;
        uint256 maturity;
        uint256 expiry;
    }

    function setUp() public {
        vm.warp(10 days);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000e18);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_500, 6_500, 10, 10);
        collateral.mint(address(this), 100e18);
        collateral.approve(address(reserve), 100e18);
        reserve.fund(50e18, 0, address(this));
    }

    function _request(uint256 amount) internal returns (uint256 series, uint256 epoch) {
        reserve.inf().approve(address(reserve), amount);
        return reserve.requestDefund(amount);
    }

    function testReportedDustHolderDoesNotDelayEarmarkedClaim() public {
        uint256 supply = reserve.inf().totalSupply();
        assertEq(supply, 150_000e18);
        assertTrue(reserve.inf().transfer(SECOND, 1));
        (uint256 series, uint256 epoch) = _request(supply - 1);
        uint256 maturity = reserve.withdrawalMaturity(series, epoch);
        vm.warp(maturity);
        // Debt-free settlement and claims remain independent of the primary oracle.
        oracle.setPrice(0);
        vm.expectEmit(true, true, false, true, address(reserve));
        emit NaNReserve.WithdrawalSettled(series, epoch, supply - 1e9, 49_999_999_999_999_666_666);
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filled, uint256 payout, bool settled,) = reserve.withdrawalEpochs(series, epoch);
        assertTrue(settled);
        assertEq(filled, supply - reserve.MIN_INF_SUPPLY());
        assertEq(payout, 49_999_999_999_999_666_666);
        assertEq(reserve.claimableWithdrawalCollateral(), payout);
        assertEq(reserve.reserveCollateral(), 50e18 - payout);
        (uint256 out, uint256 refund) = reserve.claimDefund(series, epoch, payout, address(this));
        assertEq(out, payout);
        assertEq(refund, 999_999_999);
        assertEq(block.timestamp, maturity);
        assertEq(reserve.inf().totalSupply(), reserve.MIN_INF_SUPPLY());
        assertEq(reserve.inf().balanceOf(SECOND), 1);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
    }

    function testFuzzPrecisionRemainderClaimsConserveTotals(uint96 rawSplit, bool reverse, bool withDebt) public {
        if (withDebt) reserve.mint(1, 0, address(this));
        uint256 supply = reserve.inf().totalSupply();
        _settleAndClaimTwo(supply - 1, bound(uint256(rawSplit), 1, supply - 2), reverse, withDebt);
        assertEq(reserve.inf().totalSupply(), reserve.MIN_INF_SUPPLY());
    }

    function testFuzzZeroCollateralRemainderClaimsConserveTotals(uint96 rawSplit, bool reverse) public {
        reserve.mint(50e18, 0, address(this));
        uint256 supply = reserve.inf().totalSupply();
        uint256 minimumUsd = Math.mulDiv(reserve.debtUsd(), 10_000, 5_500, Math.Rounding.Ceil);
        uint256 minimumCollateral = Math.mulDiv(minimumUsd, 1e18, 3_000e18, Math.Rounding.Ceil);
        uint256 availableUsd = (reserve.reserveCollateral() - minimumCollateral) * 3_000;
        uint256 fill = Math.mulDiv(availableUsd, supply, reserve.reserveUsd() - reserve.debtUsd());
        // The extra base unit cannot buy even one collateral base unit at NAV.
        uint256 requested = fill + 1;
        _settleAndClaimTwo(requested, bound(uint256(rawSplit), 1, requested - 1), reverse, true);
        assertEq(reserve.inf().totalSupply(), supply - fill);
        assertGt(reserve.inf().totalSupply(), reserve.MIN_INF_SUPPLY());
    }

    function _settleAndClaimTwo(uint256 requested, uint256 split, bool reverse, bool withDebt) internal {
        Snapshot memory snapshot;
        snapshot.supply = reserve.inf().totalSupply();
        assertTrue(reserve.inf().transfer(SECOND, split));
        (uint256 series, uint256 epoch) = _request(requested - split);
        vm.startPrank(SECOND);
        reserve.inf().approve(address(reserve), split);
        reserve.requestDefund(split);
        vm.stopPrank();
        snapshot.maturity = reserve.withdrawalMaturity(series, epoch);
        snapshot.expiry = reserve.withdrawalExpiry(series, epoch);
        vm.warp(snapshot.maturity);
        if (withDebt) {
            oracle.setPrice(0);
            vm.expectRevert(NaNReserve.InvalidPrice.selector);
            reserve.settleDefundEpoch(series, epoch);
            (,, uint256 beforeFill,, bool beforeSettled,) = reserve.withdrawalEpochs(series, epoch);
            assertEq(beforeFill, 0);
            assertFalse(beforeSettled);
            oracle.setPrice(3_000e18);
        }
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filled, uint256 payout, bool settled,) = reserve.withdrawalEpochs(series, epoch);
        assertTrue(settled);
        assertGt(filled, 0);
        assertLt(filled, requested);
        assertGt(payout, 0);
        assertEq(reserve.claimableWithdrawalCollateral(), payout);
        assertEq(reserve.inf().totalSupply() + filled, snapshot.supply);
        if (withDebt) assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        snapshot.backing = reserve.reserveCollateral();
        snapshot.debt = reserve.debtUsd();
        oracle.setPrice(0);
        uint256 totalOut;
        uint256 totalRefund;
        for (uint256 i; i < 2; ++i) {
            address account = (i == 0) == reverse ? SECOND : address(this);
            vm.prank(account);
            (uint256 out, uint256 refund) = reserve.claimDefund(series, epoch, 0, account);
            totalOut += out;
            totalRefund += refund;
            assertEq(reserve.claimableWithdrawalCollateral(), payout - totalOut);
            vm.prank(account);
            vm.expectRevert(NaNReserve.NoWithdrawalRequest.selector);
            reserve.claimDefund(series, epoch, 0, account);
        }
        assertEq(totalOut, payout);
        assertEq(totalRefund + filled, requested);
        assertEq(reserve.inf().balanceOf(address(this)) + reserve.inf().balanceOf(SECOND) + filled, snapshot.supply);
        assertEq(reserve.inf().balanceOf(address(reserve)), 0);
        assertEq(reserve.claimableWithdrawalCollateral(), 0);
        assertEq(reserve.reserveCollateral(), snapshot.backing);
        assertEq(reserve.debtUsd(), snapshot.debt);
        assertEq(reserve.withdrawalMaturity(series, epoch), snapshot.maturity);
        assertEq(reserve.withdrawalExpiry(series, epoch), snapshot.expiry);
        assertEq(block.timestamp, snapshot.maturity);
        vm.expectRevert(NaNReserve.WithdrawalAlreadySettled.selector);
        reserve.settleDefundEpoch(series, epoch);
        vm.warp(snapshot.expiry);
        vm.expectRevert(NaNReserve.WithdrawalAlreadySettled.selector);
        reserve.expireDefundEpoch(series, epoch);
    }
}
