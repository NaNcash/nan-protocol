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
        vm.startPrank(ATTACKER);
        collateral.approve(address(reserve), type(uint256).max);
        inf.approve(address(reserve), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(VICTIM);
        collateral.approve(address(reserve), type(uint256).max);
        inf.approve(address(reserve), type(uint256).max);
        vm.stopPrank();
    }

    function testReportedOneWeiBootstrapIsRejected() public {
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.previewFund(1);
        vm.prank(ATTACKER);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.fund(1, 0, ATTACKER);
        assertEq(inf.totalSupply(), 0);
        assertEq(reserve.reserveCollateral(), 0);
    }

    function testPositiveFractionalInfFundingKeepsSlippageProtection() public {
        oracle.setPrice(WAD);
        vm.startPrank(ATTACKER);
        reserve.fund(2 * WAD, 0, ATTACKER);
        collateral.transfer(address(reserve), WAD);
        vm.stopPrank();
        assertEq(reserve.previewFund(2), 1);
        uint256 balance = collateral.balanceOf(VICTIM);
        vm.prank(VICTIM);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.fund(2, 2, VICTIM);
        assertEq(collateral.balanceOf(VICTIM), balance);
        vm.prank(VICTIM);
        assertEq(reserve.fund(2, 1, VICTIM), 1);
        assertEq(inf.balanceOf(address(reserve)), WAD);
    }

    function testPartialExitCannotRecreateReportedTinySupply() public {
        vm.prank(ATTACKER);
        uint256 shares = reserve.fund(1e15, 0, ATTACKER);
        _withdraw(ATTACKER, shares - 3_000);
        assertEq(inf.totalSupply(), WAD + 3_000);
        vm.prank(ATTACKER);
        collateral.transfer(address(reserve), WAD);
        uint256 maximumLoss = Math.ceilDiv(reserve.reserveCollateral(), inf.totalSupply()) + 1;
        uint256 quote = reserve.previewFund(1e15);
        assertGt(quote, 0);
        assertLt(quote, WAD);
        vm.prank(VICTIM);
        reserve.fund(1e15, quote, VICTIM);
        assertGe(_withdraw(VICTIM, quote), 1e15 - maximumLoss);
    }

    function testAllUserSharesCanExitWithoutDestroyingMinimumSupply() public {
        vm.prank(ATTACKER);
        uint256 shares = reserve.fund(WAD, 0, ATTACKER);
        _withdraw(ATTACKER, shares);
        assertEq(inf.totalSupply(), WAD);
        assertEq(inf.balanceOf(address(reserve)), WAD);
        assertGt(reserve.reserveCollateral(), 0);
        uint256 quote = reserve.previewFund(1);
        vm.prank(VICTIM);
        assertEq(reserve.fund(1, quote, VICTIM), quote);
        assertEq(inf.balanceOf(address(reserve)), WAD);
    }

    function testThousandFractionalDepositsCannotProfitDonationAttacker() public {
        uint256 beforeBalance = collateral.balanceOf(ATTACKER);
        vm.startPrank(ATTACKER);
        uint256 shares = reserve.fund(WAD / 3_000 + 1, 0, ATTACKER);
        collateral.transfer(address(reserve), WAD);
        vm.stopPrank();
        for (uint256 i; i < 1_000; ++i) {
            uint256 quote = reserve.previewFund(1e15);
            assertGt(quote, 0);
            assertLt(quote, WAD);
            vm.prank(VICTIM);
            assertEq(reserve.fund(1e15, quote, VICTIM), quote);
        }
        _withdraw(ATTACKER, shares);
        assertLe(collateral.balanceOf(ATTACKER), beforeBalance);
        assertGe(inf.totalSupply(), WAD);
    }

    function testFuzzDonationRoundingLossIsBounded(uint96 rawSeed, uint96 rawDonation, uint96 rawDeposit) public {
        uint256 seed = bound(uint256(rawSeed), WAD / 3_000 + 1, 100 * WAD);
        uint256 donation = bound(uint256(rawDonation), 1, 1_000 * WAD);
        uint256 deposit = bound(uint256(rawDeposit), 1, 100 * WAD);
        vm.startPrank(ATTACKER);
        reserve.fund(seed, 0, ATTACKER);
        collateral.transfer(address(reserve), donation);
        vm.stopPrank();
        uint256 roundedQuote = Math.mulDiv(deposit, inf.totalSupply(), reserve.reserveCollateral());
        if (roundedQuote == 0) {
            assertEq(reserve.previewFund(deposit), 0);
            vm.prank(VICTIM);
            vm.expectRevert(NaNReserve.Slippage.selector);
            reserve.fund(deposit, 0, VICTIM);
            return;
        }
        uint256 maximumLoss = Math.ceilDiv(reserve.reserveCollateral(), inf.totalSupply()) + 1;
        uint256 quote = reserve.previewFund(deposit);
        vm.prank(VICTIM);
        assertEq(reserve.fund(deposit, quote, VICTIM), quote);
        uint256 withdrawn = _withdraw(VICTIM, quote);
        assertGe(withdrawn, deposit > maximumLoss ? deposit - maximumLoss : 0);
    }

    function _prepareRecoveryWithMinimumSupply() internal {
        vm.prank(ATTACKER);
        uint256 shares = reserve.fund(1e15, 0, ATTACKER);
        _withdraw(ATTACKER, shares - 1);
        assertEq(inf.totalSupply(), WAD + 1);
        vm.prank(ATTACKER);
        collateral.transfer(address(reserve), 100 * WAD);
        vm.prank(VICTIM);
        reserve.mint(180 * WAD, 0, VICTIM);
        oracle.setPrice(1_500 * WAD);
    }

    function _maximumFundingCollateral() internal view returns (uint256) {
        uint256 limitUsd = Math.mulDiv(reserve.debtUsd(), 10_000, reserve.minDebtRatioBps());
        // floor(totalCollateral * price / WAD) may equal the limit, but never exceed it.
        uint256 maximumTotal = Math.mulDiv(limitUsd + 1, WAD, oracle.price(), Math.Rounding.Ceil) - 1;
        return maximumTotal - reserve.reserveCollateral();
    }

    function testMinimumSupplyRecoveryCanBeFundedImmediatelyAtCap() public {
        _prepareRecoveryWithMinimumSupply();
        uint256 cap = _maximumFundingCollateral();
        uint256 quote = reserve.previewFund(cap);
        assertGt(quote, 0);
        uint256 timestamp = block.timestamp;
        vm.prank(VICTIM);
        assertEq(reserve.fund(cap, quote, VICTIM), quote);
        assertEq(block.timestamp, timestamp);
        assertGe(reserve.debtRatioBps(), reserve.minDebtRatioBps());
        vm.prank(VICTIM);
        vm.expectRevert(NaNReserve.DebtRatioTooLow.selector);
        reserve.fund(1, 0, VICTIM);
    }

    function testTinyRecoveryDepositCanMintLessThanOneInf() public {
        _prepareRecoveryWithMinimumSupply();
        uint256 quote = reserve.previewFund(1e12);
        assertGt(quote, 0);
        assertLt(quote, WAD);
        vm.prank(VICTIM);
        assertEq(reserve.fund(1e12, quote, VICTIM), quote);
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Insolvent));
    }

    function testRecoveryAfterSeniorRedemptionAcceptsFractionalInfAtCap() public {
        _prepareRecoveryWithMinimumSupply();
        reserve.checkpointRecovery();
        uint256 floor = reserve.recoveryFloorPriceUsd();
        uint256 debtToRedeem = reserve.debtUsd() - 100 * WAD;
        vm.prank(VICTIM);
        reserve.redeem(debtToRedeem, 0, VICTIM);
        assertEq(reserve.recoveryFloorPriceUsd(), floor);
        uint256 cap = _maximumFundingCollateral();
        uint256 quote = reserve.previewFund(cap);
        assertGt(quote, 0);
        assertLt(quote, WAD, "a fixed one-INF minimum would block every cap-allowed deposit");
        vm.prank(VICTIM);
        assertEq(reserve.fund(cap, quote, VICTIM), quote);
    }

    function testCloselySpacedRatiosAllowFractionalRecoveryFundingAtCap() public {
        _prepareRecoveryWithMinimumSupply();
        reserve.setDebtRatios(4_999, 5_000, 5_001);
        oracle.setPrice(3_852.5 ether);
        assertGt(reserve.debtUsd() * 10_000, reserve.reserveUsd() * reserve.maxDebtRatioBps());
        uint256 cap = _maximumFundingCollateral();
        uint256 quote = reserve.previewFund(cap);
        assertGt(quote, 0);
        assertLt(quote, WAD);
        vm.prank(VICTIM);
        assertEq(reserve.fund(cap, quote, VICTIM), quote);
    }

    function testFuzzMaximumRecoveryFundingRemainsAvailable(uint16 rawMin, uint16 rawMax) public {
        _prepareRecoveryWithMinimumSupply();
        uint256 maximum = bound(uint256(rawMax), 3, 9_999);
        uint256 minimum = bound(uint256(rawMin), 1, maximum - 2);
        reserve.setDebtRatios(minimum, (minimum + maximum) / 2, maximum);
        uint256 price = Math.mulDiv(reserve.debtUsd(), 10_000 * WAD, maximum * reserve.reserveCollateral()) - 1;
        oracle.setPrice(price);
        uint256 cap = _maximumFundingCollateral();
        uint256 quote = reserve.previewFund(cap);
        assertGt(quote, 0);
        collateral.mint(VICTIM, cap);
        vm.prank(VICTIM);
        assertEq(reserve.fund(cap, quote, VICTIM), quote);
        assertGe(reserve.debtRatioBps(), minimum);
    }

    function _withdraw(address account, uint256 shares) internal returns (uint256 collateralOut) {
        vm.prank(account);
        (uint256 series, uint256 epoch) = reserve.requestDefund(shares);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(account);
        uint256 unfilled;
        (collateralOut, unfilled) = reserve.claimDefund(series, epoch, 0, account);
        assertEq(unfilled, 0);
    }
}
