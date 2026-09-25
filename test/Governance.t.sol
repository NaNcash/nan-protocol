// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {IReserveOracle} from "../src/interfaces/IReserveOracle.sol";

contract GovernanceTest is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;

    function setUp() public {
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        collateral.mint(ALICE, 1_000 * WAD);
        collateral.mint(BOB, 1_000 * WAD);
        vm.prank(ALICE);
        collateral.approve(address(reserve), type(uint256).max);
        vm.prank(BOB);
        collateral.approve(address(reserve), type(uint256).max);
    }

    function _bootstrapAndMint() internal {
        vm.prank(ALICE);
        reserve.fund(100 * WAD, 0, ALICE);
        vm.prank(BOB);
        reserve.mint(180 * WAD, 0, BOB);
    }

    function testOnlyAuthorizerCanUpdateConfiguration() public {
        MockOracle replacement = new MockOracle(3_100 * WAD);
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        reserve.setDebtRatios(4_000, 5_500, 6_500);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        reserve.setFees(20, 30);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        reserve.setOracle(replacement);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        reserve.setInfWithdrawalDelay(7 days);
        vm.stopPrank();
    }

    function testAuthorizerRotationIsTwoStep() public {
        reserve.transferOwnership(BOB);
        assertEq(reserve.owner(), address(this));
        assertEq(reserve.pendingOwner(), BOB);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        reserve.acceptOwnership();

        vm.prank(BOB);
        reserve.acceptOwnership();
        assertEq(reserve.owner(), BOB);
        assertEq(reserve.pendingOwner(), address(0));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        reserve.setFees(20, 20);
        vm.prank(BOB);
        reserve.setFees(20, 20);
        assertEq(reserve.mintFeeBps(), 20);
        assertEq(reserve.redeemFeeBps(), 20);
    }

    function testCannotRenounceAuthorizer() public {
        vm.expectRevert(NaNReserve.RenounceDisabled.selector);
        reserve.renounceOwnership();
    }

    function testWithdrawalDelayBoundsAndAuthorizerRotation() public {
        assertEq(reserve.infWithdrawalDelay(), 3 days);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setInfWithdrawalDelay(1 days - 1);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setInfWithdrawalDelay(30 days + 1);

        reserve.transferOwnership(BOB);
        vm.prank(BOB);
        reserve.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        reserve.setInfWithdrawalDelay(7 days);
        vm.prank(BOB);
        reserve.setInfWithdrawalDelay(7 days);
        assertEq(reserve.infWithdrawalDelay(), 7 days);
    }

    function testInvalidConfigurationUpdatesAreRejected() public {
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setDebtRatios(0, 5_500, 6_500);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setDebtRatios(5_500, 5_500, 6_500);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setDebtRatios(5_000, 6_500, 6_500);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setDebtRatios(5_000, 6_500, 10_000);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setFees(1_001, 10);
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setFees(10, 1_001);
        vm.expectRevert(NaNReserve.ZeroAddress.selector);
        reserve.setOracle(IReserveOracle(address(0)));
        vm.expectRevert(NaNReserve.InvalidConfiguration.selector);
        reserve.setOracle(IReserveOracle(ALICE));
        MockOracle invalidOracle = new MockOracle(0);
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.setOracle(invalidOracle);
    }

    function testChangedFeesAffectNewTrades() public {
        vm.prank(ALICE);
        reserve.fund(100 * WAD, 0, ALICE);
        reserve.setFees(100, 200);

        vm.prank(BOB);
        uint256 nanOut = reserve.mint(100 * WAD, 297_000 * WAD, BOB);
        assertEq(nanOut, 297_000 * WAD);
        vm.prank(BOB);
        uint256 collateralOut = reserve.redeem(30_000 * WAD, 0, BOB);
        assertEq(collateralOut, 9_800 * WAD / 1_000);
    }

    function testMinCapsFundingTargetCapsWithdrawalsAndMaxCapsMinting() public {
        _bootstrapAndMint();
        assertEq(reserve.maxFundableUsd(), 238_920 * WAD);
        assertGt(reserve.maxDefundableUsd(), 0);

        reserve.setDebtRatios(5_000, 6_400, 6_410);
        assertGt(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertEq(reserve.maxDefundableUsd(), 0);
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.DebtRatioTooHigh.selector);
        reserve.mint(1 * WAD, 0, BOB);
        reserve.setDebtRatios(5_000, 6_450, 6_500);

        vm.prank(ALICE);
        reserve.fund(79 * WAD, 0, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.DebtRatioTooLow.selector);
        reserve.fund(1 * WAD, 0, ALICE);
    }

    function testUpdatedTargetAppliesAtWithdrawalSettlement() public {
        _bootstrapAndMint();
        vm.startPrank(ALICE);
        reserve.inf().approve(address(reserve), type(uint256).max);
        (uint256 series, uint256 epoch) = reserve.requestDefund(1_000 * WAD);
        vm.stopPrank();

        reserve.setDebtRatios(5_000, 6_400, 6_500);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(ALICE);
        (uint256 collateralOut, uint256 refundedInf) = reserve.claimDefund(series, epoch, 0, ALICE);
        assertEq(collateralOut, 0);
        assertEq(refundedInf, 1_000 * WAD);
    }

    function testOracleRouterCanBeReplacedAfterFailure() public {
        _bootstrapAndMint();
        oracle.setPrice(0);
        vm.expectRevert(NaNReserve.InvalidPrice.selector);
        reserve.collateralPriceUsd();

        MockOracle replacement = new MockOracle(3_100 * WAD);
        reserve.setOracle(replacement);
        assertEq(address(reserve.oracle()), address(replacement));
        assertEq(reserve.collateralPriceUsd(), 3_100 * WAD);
        assertGt(reserve.maxFundableUsd(), 0);
    }

    function testRecapitalizationAlsoRespectsMinimumRatio() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);
        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.DebtRatioTooLow.selector);
        reserve.recapitalize(440 * WAD, 0, ALICE);

        vm.prank(ALICE);
        reserve.recapitalize(278 * WAD, 0, ALICE);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertGe(reserve.debtRatioBps(), reserve.minDebtRatioBps());
    }
}
