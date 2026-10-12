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

        vm.prank(ALICE);
        wstETH.transfer(address(reserve), WAD / 2);
        uint256 quote = reserve.previewFund(WAD);
        vm.prank(BOB);
        assertEq(reserve.fund(WAD, quote, BOB), quote);

        (series, epoch) = _requestAndSettle(1);
        vm.prank(ALICE);
        reserve.claimDefund(series, epoch, 0, ALICE);

        assertLe(wstETH.balanceOf(ALICE), attackerBefore, "donation attack must not profit");
    }
}
