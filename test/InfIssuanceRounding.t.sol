// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {INFToken} from "../src/INFToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract InfIssuanceRoundingTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ATTACKER = address(0xA11CE);
    address internal constant VICTIM = address(0xB0B);

    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    INFToken internal inf;

    function setUp() public {
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        inf = reserve.inf();
        collateral.mint(ATTACKER, 10_000 * WAD);
        collateral.mint(VICTIM, 10_000 * WAD);
        vm.prank(ATTACKER);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(VICTIM);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(ATTACKER);
        inf.approve(address(reserve), type(uint256).max);
        vm.prank(VICTIM);
        inf.approve(address(reserve), type(uint256).max);
    }

    function _assertRejected(uint256 amount, uint256 minimum) internal {
        uint256 balance = collateral.balanceOf(VICTIM);
        uint256 backing = reserve.reserveCollateral();
        uint256 supply = inf.totalSupply();
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.previewFund(amount);
        vm.prank(VICTIM);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.fund(amount, minimum, VICTIM);
        assertEq(collateral.balanceOf(VICTIM), balance);
        assertEq(reserve.reserveCollateral(), backing);
        assertEq(inf.totalSupply(), supply);
    }

    function testIssue11OneWeiBootstrapIsRejected() public {
        // The reported attack starts with 3,000 base units of INF at $3,000.
        _assertRejected(1, 3_000);
    }

    function testDonationCannotMakeVictimAcceptFractionalInfEvenAtExactQuote() public {
        vm.startPrank(ATTACKER);
        reserve.fund(1e15, 0, ATTACKER);
        collateral.transfer(address(reserve), WAD);
        vm.stopPrank();
        uint256 oldQuote = 1e15 * inf.totalSupply() / reserve.reserveCollateral();
        assertGt(oldQuote, 0);
        assertLt(oldQuote, WAD);
        _assertRejected(1e15, oldQuote);
    }

    function testRecoveryRejectsTinyIssuanceWithoutPersistingEpisode() public {
        vm.prank(ATTACKER);
        reserve.fund(100 * WAD, 0, ATTACKER);
        vm.prank(VICTIM);
        reserve.mint(180 * WAD, 0, VICTIM);
        oracle.setPrice(1_500 * WAD);
        assertGt(reserve.recoveryFloorPriceUsd(), 0);
        _assertRejected(1e12, 0);
        (, uint256 initialPrice,,) = reserve.recovery();
        assertEq(initialPrice, 0);
    }
}
