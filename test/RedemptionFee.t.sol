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
        collateral.transfer(address(reserve), amount);
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
}
