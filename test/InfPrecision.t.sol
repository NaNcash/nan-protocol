// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";

contract InfPrecisionTest is Test {
    MockERC20 internal collateral;
    NaNReserve internal reserve;
    address internal constant VICTIM = address(0xB0B);

    function setUp() public {
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        reserve = new NaNReserve(collateral, new MockOracle(3_000e18), address(this), 3_000, 5_500, 6_500, 10, 10);
        collateral.mint(address(this), 1_000_000e18);
        collateral.mint(VICTIM, 10_000e18);
        collateral.approve(address(reserve), type(uint256).max);
        reserve.inf().approve(address(reserve), type(uint256).max);
        vm.prank(VICTIM);
        collateral.approve(address(reserve), type(uint256).max);
    }

    function testReportedDustBootstrapRevertsWithoutTakingCollateral() public {
        uint256 beforeBalance = collateral.balanceOf(address(this));
        vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
        reserve.fund(1, 0, address(this));
        assertEq(collateral.balanceOf(address(this)), beforeBalance);
        assertEq(reserve.inf().totalSupply(), 0);
    }

    function testNearDrainKeepsMinimumSupplyAndCompleteExitCanRestart() public {
        uint256 supply = reserve.fund(1_000_000, 0, address(this));
        (uint256 series, uint256 epoch) = reserve.requestDefund(supply - 1);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        (,,,, bool settled,) = reserve.withdrawalEpochs(series, epoch);
        if (!settled) {
            vm.warp(reserve.withdrawalExpiry(series, epoch));
            reserve.expireDefundEpoch(series, epoch);
        }
        reserve.claimDefund(series, epoch, 0, address(this));
        assertEq(reserve.inf().totalSupply(), reserve.MIN_INF_SUPPLY());
        assertEq(reserve.inf().balanceOf(address(this)), reserve.MIN_INF_SUPPLY());

        (series, epoch) = reserve.requestDefund(reserve.MIN_INF_SUPPLY());
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        reserve.claimDefund(series, epoch, 0, address(this));
        assertEq(reserve.inf().totalSupply(), 0);
        assertEq(reserve.reserveCollateral(), 0);
        assertGt(reserve.fund(1_000_000, 0, address(this)), 0);
    }

    function testDonationCannotForceCoarseVictimDepositEvenWithZeroMinimum() public {
        reserve.fund(1_000_000, 0, address(this));
        collateral.transfer(address(reserve), 10_000e18);
        uint256 beforeBalance = collateral.balanceOf(VICTIM);
        vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
        reserve.previewFund(1.999e18);
        vm.prank(VICTIM);
        vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
        reserve.fund(1.999e18, 0, VICTIM);
        assertEq(collateral.balanceOf(VICTIM), beforeBalance);
    }

    function testFuzzDonationRoundingLossIsBounded(uint96 rawDonation, uint96 rawDeposit) public {
        reserve.fund(1e12, 0, address(this));
        collateral.transfer(address(reserve), bound(uint256(rawDonation), 0, 100_000e18));
        uint256 deposit = bound(uint256(rawDeposit), 1, 10_000e18);
        uint256 supplyBefore = reserve.inf().totalSupply();
        uint256 backingBefore = reserve.reserveCollateral();
        uint256 exactFloor = Math.mulDiv(deposit, supplyBefore, backingBefore);
        if (exactFloor < reserve.MIN_INF_SUPPLY()) {
            vm.prank(VICTIM);
            vm.expectRevert(NaNReserve.InsufficientInfPrecision.selector);
            reserve.fund(deposit, 0, VICTIM);
            return;
        }
        vm.prank(VICTIM);
        uint256 minted = reserve.fund(deposit, 0, VICTIM);
        uint256 claim = Math.mulDiv(minted, reserve.reserveCollateral(), reserve.inf().totalSupply());
        assertLe(deposit - claim, Math.ceilDiv(deposit, reserve.MIN_INF_SUPPLY()) + 1);
    }
}
