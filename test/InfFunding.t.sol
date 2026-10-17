// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";

contract InfFundingTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;

    function setUp() public {
        collateral = new MockERC20("Collateral", "COL");
        oracle = new MockOracle(WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_500, 6_500, 0, 0);
        collateral.mint(ALICE, 1e30);
        collateral.mint(BOB, 1e30);
        vm.prank(ALICE);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(BOB);
        collateral.approve(address(reserve), type(uint256).max);
    }

    function _bootstrapAndMint() internal {
        vm.prank(ALICE);
        reserve.fund(70 * WAD, 0, ALICE);
        vm.prank(BOB);
        reserve.mint(30 * WAD, 0, BOB);
        assertEq(reserve.reserveUsd(), 100 * WAD);
        assertEq(reserve.debtUsd(), 30 * WAD);
    }

    function _fundAndMatchPreview(uint256 amount) internal returns (uint256 issued) {
        uint256 quote = reserve.previewFund(amount);
        vm.prank(BOB);
        issued = reserve.fund(amount, quote, BOB);
        assertEq(issued, quote);
    }

    function testFundingCrossesFormerThirtyPercentMinimumAtNav() public {
        _bootstrapAndMint();
        assertEq(reserve.debtRatioBps(), 3_000);
        assertEq(_fundAndMatchPreview(10 * WAD), 10 * WAD);
        assertEq(reserve.debtRatioBps(), 2_727);
        assertEq(reserve.infPriceUsd(), WAD);
        assertEq(reserve.inf().balanceOf(ALICE), 70 * WAD);
        assertEq(reserve.debtUsd(), 30 * WAD);
        // Further funding is also accepted from below the former minimum.
        assertEq(_fundAndMatchPreview(1_000 * WAD), 1_000 * WAD);
        assertEq(reserve.infPriceUsd(), WAD);
    }

    function testFundingBelowFormerMinimumAfterAppreciation() public {
        _bootstrapAndMint();
        oracle.setPrice(2 * WAD);
        assertEq(reserve.debtRatioBps(), 1_500);
        uint256 supply = reserve.inf().totalSupply();
        uint256 equity = reserve.equityUsd();
        assertEq(_fundAndMatchPreview(10 * WAD), Math.mulDiv(20 * WAD, supply, equity));
        assertGe(Math.mulDiv(reserve.equityUsd(), supply, reserve.inf().totalSupply()), equity);
    }

    function testFundingBelowFormerMinimumAfterRedemption() public {
        _bootstrapAndMint();
        vm.prank(BOB);
        reserve.redeem(10 * WAD, 0, BOB);
        assertLt(reserve.debtRatioBps(), 3_000);
        assertEq(_fundAndMatchPreview(100 * WAD), 100 * WAD);
        assertEq(reserve.debtUsd(), 20 * WAD);
        assertEq(reserve.infPriceUsd(), WAD);
    }

    function testLargeBootstrapAndDebtFreeFunding() public {
        assertEq(_fundAndMatchPreview(1_000_000 * WAD), 1_000_000 * WAD);
        oracle.setPrice(2 * WAD);
        assertEq(_fundAndMatchPreview(1_000_000 * WAD), 1_000_000 * WAD);
        assertEq(reserve.debtUsd(), 0);
        assertEq(reserve.infPriceUsd(), 2 * WAD);
    }

    function testFundingThroughFormerMinimumKeepsMintAndWithdrawalLimits() public {
        _bootstrapAndMint();
        _fundAndMatchPreview(100 * WAD);
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.DebtRatioTooHigh.selector);
        reserve.mint(300 * WAD, 0, BOB);

        vm.startPrank(ALICE);
        reserve.inf().approve(address(reserve), 70 * WAD);
        (uint256 series, uint256 epoch) = reserve.requestDefund(70 * WAD);
        vm.stopPrank();
        // A tighter live target limits settlement even after uncapped funding.
        reserve.setDebtRatios(1_600, 6_500);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        (, uint256 requested, uint256 filled,,,) = reserve.withdrawalEpochs(series, epoch);
        assertGt(filled, 0);
        assertLt(filled, requested);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertGe(reserve.reserveUsd(), Math.mulDiv(reserve.debtUsd(), 10_000, 1_600, Math.Rounding.Ceil));
    }

    function testFuzzNormalFundingPreservesNavAndCannotBenefitFromSplitting(
        uint96 rawAmount,
        uint96 rawSplit,
        uint96 rawPrice
    ) public {
        _bootstrapAndMint();
        // Appreciation gives a fractional NAV and ratios below the former minimum.
        oracle.setPrice(bound(uint256(rawPrice), WAD, 100_000 * WAD));
        uint256 amount = bound(uint256(rawAmount), 2e12, 1_000_000 * WAD);
        uint256 split = bound(uint256(rawSplit), 1e12, amount - 1e12);
        uint256 supply = reserve.inf().totalSupply();
        uint256 equity = reserve.equityUsd();
        uint256 nav = reserve.infPriceUsd();
        uint256 snapshot = vm.snapshotState();
        uint256 whole = _fundAndMatchPreview(amount);
        // Existing holders retain their total NAV; rounding costs less than one base share
        // plus the one USD base unit from collateral conversion.
        uint256 oldClaim = Math.mulDiv(reserve.equityUsd(), supply, reserve.inf().totalSupply());
        assertGe(oldClaim, equity);
        assertLe(oldClaim - equity, Math.ceilDiv(equity, supply) + 1);
        assertGe(reserve.infPriceUsd(), nav);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        uint256 parts = _fundAndMatchPreview(split);
        parts += _fundAndMatchPreview(amount - split);
        assertLe(parts, whole);
        assertEq(reserve.debtUsd(), 30 * WAD);
    }
}
