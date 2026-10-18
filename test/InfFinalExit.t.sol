// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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

    function setUp() public {
        vm.warp(10 days);
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000e18);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_500, 6_500, 0, 0);
        inf = reserve.inf();
        collateral.mint(address(this), 100e18);
        collateral.approve(address(reserve), type(uint256).max);
        inf.approve(address(reserve), type(uint256).max);
        vm.prank(SECOND);
        inf.approve(address(reserve), type(uint256).max);
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
        uint256 supply = reserve.fund(1_000_000, 0, address(this));
        uint256 epoch = _request(address(this), supply - reserve.MIN_INF_SUPPLY());
        _settle(epoch);
        reserve.claimDefund(1, epoch, 0, address(this));
        assertEq(inf.totalSupply(), reserve.MIN_INF_SUPPLY());
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
}
