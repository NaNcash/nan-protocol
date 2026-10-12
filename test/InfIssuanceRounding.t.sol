// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
        assertTrue(collateral.transfer(address(reserve), WAD));
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

    function testBootstrapAcceptsExactlyOneInfAndRejectsOneUnitLess() public {
        oracle.setPrice(WAD);
        _assertRejected(WAD - 1, 0);
        assertEq(reserve.previewFund(WAD), WAD);
        vm.prank(VICTIM);
        assertEq(reserve.fund(WAD, WAD, VICTIM), WAD);
        assertEq(reserve.infPriceUsd(), WAD);
    }

    function testNavFundingAcceptsExactlyOneInfAndKeepsUserSlippageCheck() public {
        oracle.setPrice(WAD);
        vm.startPrank(ATTACKER);
        reserve.fund(WAD, WAD, ATTACKER);
        assertTrue(collateral.transfer(address(reserve), WAD));
        vm.stopPrank();
        // NAV is $2: two collateral units mint one INF base unit.
        _assertRejected(2 * WAD - 1, WAD - 1);
        assertEq(reserve.previewFund(2 * WAD), WAD);
        vm.prank(VICTIM);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.fund(2 * WAD, WAD + 1, VICTIM);
        vm.prank(VICTIM);
        assertEq(reserve.fund(2 * WAD, WAD, VICTIM), WAD);
    }

    function testFullDebtFreeExitCannotReopenTinyBootstrap() public {
        vm.prank(ATTACKER);
        uint256 shares = reserve.fund(WAD, 0, ATTACKER);
        assertEq(_withdraw(ATTACKER, shares), WAD);
        assertEq(inf.totalSupply(), 0);
        assertEq(reserve.reserveCollateral(), 0);
        _assertRejected(1, 0);
    }

    function testPartialExitCannotRecreateIssue11RoundingAttack() public {
        vm.prank(ATTACKER);
        uint256 shares = reserve.fund(1e15, 0, ATTACKER);
        _withdraw(ATTACKER, shares - 3_000);
        // A valid bootstrap followed by a partial exit can reproduce the original tiny supply.
        assertEq(inf.totalSupply(), 3_000);
        assertEq(reserve.reserveCollateral(), 1);
        vm.prank(ATTACKER);
        assertTrue(collateral.transfer(address(reserve), WAD));
        _assertRejected(1e15, 2);
    }

    function testThousandDepositsCannotAccumulateMaterialDonationAttackProfit() public {
        uint256 seed = 1e15;
        uint256 donation = WAD;
        vm.startPrank(ATTACKER);
        uint256 shares = reserve.fund(seed, 0, ATTACKER);
        assertTrue(collateral.transfer(address(reserve), donation));
        vm.stopPrank();
        for (uint256 i; i < 1_000; ++i) {
            uint256 quote = reserve.previewFund(WAD);
            assertGe(quote, WAD);
            vm.prank(VICTIM);
            assertEq(reserve.fund(WAD, quote, VICTIM), quote);
        }
        // At most one wei of issuance rounding per one-wstETH deposit.
        assertLe(_withdraw(ATTACKER, shares), seed + donation + 1_000);
    }

    function testFuzzDonationRoundingLossIsBounded(uint96 rawSeed, uint96 rawDonation, uint96 rawDeposit) public {
        uint256 seed = bound(uint256(rawSeed), (WAD + 2_999) / 3_000, 100 * WAD);
        uint256 donation = bound(uint256(rawDonation), 1, 1_000 * WAD);
        uint256 deposit = bound(uint256(rawDeposit), 1, 100 * WAD);
        vm.startPrank(ATTACKER);
        reserve.fund(seed, 0, ATTACKER);
        assertTrue(collateral.transfer(address(reserve), donation));
        vm.stopPrank();
        uint256 exactRoundedQuote = Math.mulDiv(deposit, inf.totalSupply(), reserve.reserveCollateral());
        if (exactRoundedQuote < WAD) {
            _assertRejected(deposit, exactRoundedQuote);
            return;
        }
        uint256 quote = reserve.previewFund(deposit);
        vm.prank(VICTIM);
        uint256 shares = reserve.fund(deposit, quote, VICTIM);
        // Bound the victim's actual deposit/withdrawal loss, including collateral rounding.
        uint256 maximumLoss = Math.ceilDiv(deposit, WAD) + 1;
        assertGe(_withdraw(VICTIM, shares), deposit > maximumLoss ? deposit - maximumLoss : 0);
    }

    function _withdraw(address account, uint256 shares) internal returns (uint256 collateralOut) {
        vm.prank(account);
        (uint256 series, uint256 epoch) = reserve.requestDefund(shares);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(account);
        uint256 refund;
        (collateralOut, refund) = reserve.claimDefund(series, epoch, 0, account);
        assertEq(refund, 0);
    }
}
