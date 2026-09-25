// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockERC20, MockERC20Decimals, MockFeeOnTransferERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {NaNToken} from "../src/NaNToken.sol";
import {INFToken} from "../src/INFToken.sol";

contract NaNReserveTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal wstETH;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    NaNToken internal nan;
    INFToken internal inf;

    function setUp() public {
        wstETH = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        reserve = new NaNReserve(wstETH, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        nan = reserve.nan();
        inf = reserve.inf();

        wstETH.mint(ALICE, 2_000 * WAD);
        wstETH.mint(BOB, 2_000 * WAD);

        vm.prank(ALICE);
        wstETH.approve(address(reserve), type(uint256).max);
        vm.prank(BOB);
        wstETH.approve(address(reserve), type(uint256).max);
        vm.prank(ALICE);
        inf.approve(address(reserve), type(uint256).max);
        vm.prank(BOB);
        inf.approve(address(reserve), type(uint256).max);
    }

    function _bootstrap() internal {
        vm.prank(ALICE);
        reserve.fund(100 * WAD, 0, ALICE);
    }

    function _bootstrapAndMint() internal {
        _bootstrap();
        vm.prank(BOB);
        reserve.mint(180 * WAD, 0, BOB);
    }

    function _requestAndSettle(uint256 amount) internal returns (uint256 series, uint256 epoch) {
        vm.prank(ALICE);
        (series, epoch) = reserve.requestDefund(amount);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
    }

    function testDeploymentCreatesPermitTokensAndFirstJuniorSeries() public view {
        assertEq(nan.name(), "NaN");
        assertEq(inf.name(), "NaN Junior");
        assertEq(nan.reserve(), address(reserve));
        assertEq(inf.reserve(), address(reserve));
        assertEq(reserve.juniorSeries(), 1);
        assertTrue(nan.DOMAIN_SEPARATOR() != bytes32(0));
        assertTrue(inf.DOMAIN_SEPARATOR() != bytes32(0));
    }

    function testConstructorRejectsNon18DecimalCollateral() public {
        MockERC20Decimals usdc = new MockERC20Decimals("USD Coin", "USDC", 6);
        vm.expectRevert(NaNReserve.UnsupportedCollateralDecimals.selector);
        new NaNReserve(usdc, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
    }

    function testConstructorRejectsInvalidParameters() public {
        vm.expectRevert(NaNReserve.ZeroAddress.selector);
        new NaNReserve(MockERC20(address(0)), oracle, address(this), 5_000, 6_450, 6_500, 10, 10);

        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        new NaNReserve(wstETH, oracle, address(this), 5_000, 6_450, 10_000, 10, 10);

        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        new NaNReserve(wstETH, oracle, address(this), 5_000, 6_450, 6_500, 10_000, 10);
    }

    function testInitialFundingStartsInfAtOneDollar() public {
        _bootstrap();
        assertEq(inf.balanceOf(ALICE), 300_000 * WAD);
        assertEq(reserve.infPriceUsd(), WAD);
        assertEq(reserve.reserveUsd(), 300_000 * WAD);
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.NoDebt));
    }

    function testHealthAndPriceViewsAcrossMarketStates() public {
        assertEq(reserve.nanRedemptionPriceUsd(), WAD);
        assertEq(reserve.collateralRatio(), type(uint256).max);
        assertEq(reserve.maxDefundableUsd(), 0);

        _bootstrapAndMint();
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Healthy));
        assertGt(reserve.maxDefundableUsd(), 0);

        oracle.setPrice(2_200 * WAD);
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Stressed));
        assertEq(reserve.maxDefundableUsd(), 0);
        assertEq(reserve.nanRedemptionPriceUsd(), WAD);

        oracle.setPrice(1_800 * WAD);
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Insolvent));
        assertLt(reserve.nanRedemptionPriceUsd(), WAD);
    }

    function testFundingUsesCurrentResidualNav() public {
        _bootstrapAndMint();
        uint256 priceBefore = reserve.infPriceUsd();

        vm.prank(ALICE);
        uint256 infOut = reserve.fund(10 * WAD, 0, ALICE);

        assertEq(infOut, 30_000 * WAD * WAD / priceBefore);
        assertApproxEqAbs(reserve.infPriceUsd(), priceBefore, 1);
    }

    function testMintRespectsDebtRatioAndLeavesFeeAsEquity() public {
        _bootstrapAndMint();
        assertEq(nan.balanceOf(BOB), 539_460 * WAD);
        assertLe(reserve.debtRatioBps(), 6_500);
        assertEq(reserve.equityUsd(), 300_540 * WAD);
    }

    function testMintRequiresActiveJuniorCapitalEvenAfterDonation() public {
        vm.prank(ALICE);
        assertTrue(wstETH.transfer(address(reserve), 100 * WAD));

        vm.prank(BOB);
        vm.expectRevert(NaNReserve.NoJuniorCapital.selector);
        reserve.mint(10 * WAD, 0, BOB);

        assertEq(nan.totalSupply(), 0);
    }

    function testMintTooLargeRevertsWithoutPullingCollateral() public {
        _bootstrap();
        uint256 beforeBalance = wstETH.balanceOf(BOB);
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.DebtRatioTooHigh.selector);
        reserve.mint(200 * WAD, 0, BOB);
        assertEq(wstETH.balanceOf(BOB), beforeBalance);
    }

    function testMintSlippageProtection() public {
        _bootstrap();
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.mint(10 * WAD, 29_971 * WAD, BOB);
    }

    function testWstEthYieldAccruesOnlyToInf() public {
        _bootstrapAndMint();
        uint256 infPriceBefore = reserve.infPriceUsd();

        oracle.setPrice(3_030 * WAD);

        assertGt(reserve.infPriceUsd(), infPriceBefore);
        assertEq(nan.totalSupply(), 539_460 * WAD);
    }

    function testDefundCannotBreakCollateralLimit() public {
        _bootstrapAndMint();
        (uint256 series, uint256 epoch) = _requestAndSettle(20_000 * WAD);
        (,, uint256 filledInf, uint256 collateralOut,,) = reserve.withdrawalEpochs(series, epoch);
        assertGt(filledInf, 0);
        assertLt(filledInf, 20_000 * WAD);
        assertGt(collateralOut, 0);
        vm.prank(ALICE);
        (uint256 claimed, uint256 refunded) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(claimed, collateralOut);
        assertEq(refunded, 20_000 * WAD - filledInf);
        assertLe(reserve.debtRatioBps(), 6_500);
    }

    function testAllInfCanDefundWhenThereIsNoDebt() public {
        _bootstrap();
        uint256 infSupply = inf.totalSupply();
        (uint256 series, uint256 epoch) = _requestAndSettle(infSupply);
        vm.prank(ALICE);
        (uint256 collateralOut,) = reserve.claimDefund(series, epoch, 100 * WAD, ALICE);
        assertEq(collateralOut, 100 * WAD);
        assertEq(inf.totalSupply(), 0);
        assertEq(reserve.reserveCollateral(), 0);
    }

    function testFullNoDebtDefundDoesNotTrapRoundingDust() public {
        _bootstrap();
        oracle.setPrice(3_333 * WAD + 17);
        uint256 infSupply = inf.totalSupply();
        (uint256 series, uint256 epoch) = _requestAndSettle(infSupply);

        vm.prank(ALICE);
        (uint256 collateralOut,) = reserve.claimDefund(series, epoch, 100 * WAD, ALICE);

        assertEq(collateralOut, 100 * WAD);
        assertEq(reserve.reserveCollateral(), 0);
    }

    function testCannotRedeemWithoutDebtOrDefundWithoutEquity() public {
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.NoDebt.selector);
        reserve.redeem(1, 0, ALICE);

        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);
        (uint256 series, uint256 epoch) = _requestAndSettle(1);
        vm.prank(ALICE);
        (uint256 collateralOut, uint256 refundedInf) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(collateralOut, 0);
        assertEq(refundedInf, 1);
    }

    function testHealthyRedemptionLeavesFeeForInfAndImprovesHealth() public {
        _bootstrapAndMint();
        uint256 infPriceBefore = reserve.infPriceUsd();
        uint256 ratioBefore = reserve.debtRatioBps();

        vm.prank(BOB);
        uint256 collateralOut = reserve.redeem(10_000 * WAD, 0, BOB);

        assertEq(collateralOut, 3_330 * WAD / 1_000);
        assertGt(reserve.infPriceUsd(), infPriceBefore);
        assertLt(reserve.debtRatioBps(), ratioBefore);
    }

    function testInsolventRedemptionIsProRataAndFeeFree() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);
        uint256 ratioBefore = reserve.collateralRatio();

        uint256 bobBefore = wstETH.balanceOf(BOB);
        vm.prank(BOB);
        reserve.redeem(10_000 * WAD, 0, BOB);

        assertGt(wstETH.balanceOf(BOB) - bobBefore, 0);
        assertApproxEqAbs(reserve.collateralRatio(), ratioBefore, 2);
    }

    function testFinalInsolventRedeemerReceivesEveryCollateralUnit() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);
        uint256 collateralBefore = reserve.reserveCollateral();
        uint256 nanBalance = nan.balanceOf(BOB);

        vm.prank(BOB);
        uint256 collateralOut = reserve.redeem(nanBalance, 0, BOB);

        assertEq(collateralOut, collateralBefore);
        assertEq(reserve.reserveCollateral(), 0);
        assertEq(nan.totalSupply(), 0);
    }

    function testFinalRedeemerReceivesEveryCollateralUnitAtExactSolvencyBoundary() public {
        _bootstrap();
        vm.prank(BOB);
        reserve.mint(100 * WAD, 0, BOB);

        oracle.setPrice(1_498_500_000_000_000_000_000);
        assertEq(reserve.reserveUsd(), nan.totalSupply());

        uint256 collateralBefore = reserve.reserveCollateral();
        uint256 nanBalance = nan.balanceOf(BOB);
        vm.prank(BOB);
        uint256 collateralOut = reserve.redeem(nanBalance, 0, BOB);

        assertEq(collateralOut, collateralBefore);
        assertEq(reserve.reserveCollateral(), 0);
        assertEq(nan.totalSupply(), 0);
    }

    function testCanRestartAfterFinalInsolventRedemption() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);
        INFToken retiredInf = reserve.inf();
        uint256 nanBalance = nan.balanceOf(BOB);

        vm.prank(BOB);
        reserve.redeem(nanBalance, 0, BOB);
        vm.prank(ALICE);
        uint256 infOut = reserve.recapitalize(10 * WAD, 15_000 * WAD, ALICE);

        assertEq(infOut, 15_000 * WAD);
        assertNotEq(address(reserve.inf()), address(retiredInf));
        assertEq(reserve.infPriceUsd(), WAD);
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.NoDebt));
    }

    function testFreshEmptyReserveUsesFundRatherThanRecapitalize() public {
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.NotInsolvent.selector);
        reserve.recapitalize(10 * WAD, 0, ALICE);
    }

    function testOrdinaryFundingCannotSubsidizeUnderwaterInf() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);

        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.RecapitalizationRequired.selector);
        reserve.fund(100 * WAD, 0, ALICE);
    }

    function testRecapitalizationRestoresHealthyRatioAndRetiresOldInf() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);
        INFToken retiredInf = reserve.inf();
        assertEq(reserve.equityUsd(), 0);

        vm.prank(ALICE);
        uint256 infOut = reserve.recapitalize(278 * WAD, 297_540 * WAD, ALICE);

        INFToken newInf = reserve.inf();
        assertNotEq(address(newInf), address(retiredInf));
        assertEq(reserve.juniorSeries(), 2);
        assertEq(infOut, 297_540 * WAD);
        assertEq(newInf.balanceOf(ALICE), infOut);
        assertEq(newInf.totalSupply(), infOut);
        assertEq(retiredInf.balanceOf(ALICE), 300_000 * WAD);
        assertEq(reserve.infPriceUsd(), WAD);
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Healthy));
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
    }

    function testRecapitalizationMustRestoreHealthyRatio() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);

        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.InsufficientRecapitalization.selector);
        reserve.recapitalize(277 * WAD, 0, ALICE);
    }

    function testRecapitalizationSlippageProtection() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);

        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.Slippage.selector);
        reserve.recapitalize(278 * WAD, 297_540 * WAD + 1, ALICE);
    }

    function testRecapitalizationOnlyDuringInsolvency() public {
        _bootstrapAndMint();
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.NotInsolvent.selector);
        reserve.recapitalize(100 * WAD, 0, ALICE);
    }

    function testRetiredInfCannotWithdrawFromReserve() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);
        INFToken retiredInf = reserve.inf();
        vm.prank(ALICE);
        reserve.recapitalize(278 * WAD, 0, BOB);

        vm.prank(BOB);
        reserve.fund(100 * WAD, 0, BOB);

        INFToken activeInf = reserve.inf();
        vm.prank(ALICE);
        activeInf.approve(address(reserve), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1 * WAD));
        reserve.requestDefund(1 * WAD);

        assertEq(retiredInf.balanceOf(ALICE), 300_000 * WAD);
    }

    function testRejectsZeroOraclePrice() public {
        oracle.setPrice(0);
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.reserveUsd();
    }

    function testRejectsFeeOnTransferCollateral() public {
        MockFeeOnTransferERC20 feeToken = new MockFeeOnTransferERC20();
        NaNReserve feeReserve = new NaNReserve(feeToken, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        feeToken.mint(ALICE, 100 * WAD);
        vm.startPrank(ALICE);
        feeToken.approve(address(feeReserve), type(uint256).max);
        vm.expectRevert(NaNReserve.UnsupportedTransferFee.selector);
        feeReserve.fund(10 * WAD, 0, ALICE);
        vm.stopPrank();
    }

    function testOnlyReserveCanMintOrBurnTokens() public {
        vm.expectRevert(NaNToken.OnlyReserve.selector);
        nan.mint(ALICE, 1);
        vm.expectRevert(INFToken.OnlyReserve.selector);
        inf.mint(ALICE, 1);
        vm.expectRevert(NaNToken.OnlyReserve.selector);
        nan.burn(ALICE, 1);
        vm.expectRevert(INFToken.OnlyReserve.selector);
        inf.burn(ALICE, 1);
    }

    function testInputValidation() public {
        vm.expectRevert(NaNReserve.ZeroAmount.selector);
        reserve.fund(0, 0, ALICE);
        vm.expectRevert(NaNReserve.ZeroAmount.selector);
        reserve.mint(0, 0, ALICE);
        vm.expectRevert(NaNReserve.ZeroAmount.selector);
        reserve.requestDefund(0);
        vm.expectRevert(NaNReserve.ZeroAmount.selector);
        reserve.redeem(0, 0, ALICE);
        vm.expectRevert(NaNReserve.ZeroAmount.selector);
        reserve.recapitalize(0, 0, ALICE);

        vm.expectRevert(NaNReserve.ZeroAddress.selector);
        reserve.fund(1, 0, address(0));
    }

    function testFuzzSuccessfulMintNeverExceedsDebtLimit(uint96 rawCollateralIn) public {
        _bootstrap();
        uint256 collateralIn = bound(uint256(rawCollateralIn), 1e15, 186 * WAD);

        vm.prank(BOB);
        reserve.mint(collateralIn, 0, BOB);

        assertLe(reserve.debtRatioBps(), reserve.maxDebtRatioBps());
        assertLe(reserve.debtUsd(), reserve.reserveUsd() * 6_500 / 10_000);
    }

    function testFuzzHealthyRedemptionNeverWorsensDebtRatio(uint96 rawNanIn) public {
        _bootstrapAndMint();
        uint256 nanIn = bound(uint256(rawNanIn), 3_003, nan.balanceOf(BOB));
        uint256 ratioBefore = reserve.collateralRatio();

        vm.prank(BOB);
        reserve.redeem(nanIn, 0, BOB);

        if (nan.totalSupply() != 0) assertGe(reserve.collateralRatio(), ratioBefore);
    }
}
