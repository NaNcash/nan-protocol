// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {NaNReserve} from "../../src/NaNReserve.sol";
import {NaNToken} from "../../src/NaNToken.sol";
import {INFToken} from "../../src/INFToken.sol";

contract NaNReserveHandler is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 public immutable collateral;
    MockOracle public immutable primaryOracle;
    MockOracle public immutable alternateOracle;
    NaNReserve public immutable reserve;
    uint256 public lastWithdrawalSeries;
    uint256 public lastWithdrawalEpoch;
    bool public hasWithdrawal;
    uint256[] public withdrawalEpochIds;
    uint256[] public withdrawalMaturities;

    constructor(MockERC20 collateral_, MockOracle primaryOracle_, MockOracle alternateOracle_, NaNReserve reserve_) {
        collateral = collateral_;
        primaryOracle = primaryOracle_;
        alternateOracle = alternateOracle_;
        reserve = reserve_;
        collateral.approve(address(reserve_), type(uint256).max);
    }

    function acceptOwnership() external {
        reserve.acceptOwnership();
    }

    function initialize() external {
        reserve.fund(100 * WAD, 0, address(this));
        reserve.mint(180 * WAD, 0, address(this));
    }

    function fund(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e12, 500 * WAD);
        try reserve.fund(amount, 0, address(this)) {} catch {}
    }

    function mint(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e12, 100 * WAD);
        try reserve.mint(amount, 0, address(this)) {} catch {}
    }

    function requestDefund(uint96 rawAmount) external {
        uint256 balance = reserve.inf().balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        reserve.inf().approve(address(reserve), amount);
        try reserve.requestDefund(amount) returns (uint256 series, uint256 epoch) {
            if (withdrawalEpochIds.length == 0 || withdrawalEpochIds[withdrawalEpochIds.length - 1] != epoch) {
                withdrawalEpochIds.push(epoch);
                withdrawalMaturities.push(reserve.withdrawalMaturity(series, epoch));
            }
            lastWithdrawalSeries = series;
            lastWithdrawalEpoch = epoch;
            hasWithdrawal = true;
        } catch {}
    }

    function processWithdrawal() external {
        if (!hasWithdrawal) return;
        uint256 series = lastWithdrawalSeries;
        uint256 epoch = lastWithdrawalEpoch;
        uint256 maturity = reserve.withdrawalMaturity(series, epoch);
        if (block.timestamp < maturity) vm.warp(maturity);
        if (block.timestamp >= reserve.withdrawalExpiry(series, epoch)) {
            try reserve.expireDefundEpoch(series, epoch) {} catch {}
        } else {
            try reserve.settleDefundEpoch(series, epoch) {} catch {}
        }
        try reserve.claimDefund(series, epoch, 0, address(this)) {
            hasWithdrawal = false;
        } catch {}
    }

    function redeem(uint96 rawAmount) external {
        uint256 balance = reserve.nan().balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        try reserve.redeem(amount, 0, address(this)) {} catch {}
    }

    function movePrice(uint96 rawPrice) external {
        _activeOracle().setPrice(bound(uint256(rawPrice), 100 * WAD, 6_000 * WAD));
    }

    function crash() external {
        _activeOracle().setPrice(500 * WAD);
    }

    function recover() external {
        _activeOracle().setPrice(3_000 * WAD);
    }

    function setDebtRatios(uint16 rawMin, uint16 rawTarget, uint16 rawMax) external {
        uint256 minBps = bound(uint256(rawMin), 1_000, 8_500);
        uint256 targetBps = bound(uint256(rawTarget), minBps + 1, 9_500);
        uint256 maxBps = bound(uint256(rawMax), targetBps + 1, 9_999);
        (, uint256 initialPrice, uint256 halvingPeriod, uint256 exitDebtRatio) = reserve.recovery();
        reserve.setDebtRatios(minBps, targetBps, maxBps);
        if (initialPrice != 0) {
            (, uint256 currentPrice, uint256 currentPeriod, uint256 currentExitRatio) = reserve.recovery();
            assertEq(currentPrice, initialPrice);
            assertEq(currentPeriod, halvingPeriod);
            assertEq(currentExitRatio, exitDebtRatio);
        }
    }

    function setFees(uint16 rawMint, uint16 rawRedeem) external {
        reserve.setFees(bound(uint256(rawMint), 0, 1_000), bound(uint256(rawRedeem), 0, 1_000));
    }

    function setWithdrawalDelay(uint32 rawDelay) external {
        reserve.setInfWithdrawalDelay(bound(uint256(rawDelay), 1 days, 30 days));
    }

    function setWithdrawalEpoch(uint32 rawLength) external {
        (uint256 epochBefore, uint256 endBefore) = reserve.currentWithdrawalEpoch();
        reserve.setInfWithdrawalEpoch(bound(uint256(rawLength), 1 hours, 7 days));
        (uint256 epochAfter, uint256 endAfter) = reserve.currentWithdrawalEpoch();
        assertEq(epochAfter, epochBefore);
        assertEq(endAfter, endBefore);
    }

    function setRecoveryHalvingPeriod(uint32 rawPeriod) external {
        (, uint256 initialPrice, uint256 periodBefore, uint256 exitDebtRatio) = reserve.recovery();
        reserve.setRecoveryHalvingPeriod(bound(uint256(rawPeriod), 1 hours, 30 days));
        if (initialPrice != 0) {
            (, uint256 currentPrice, uint256 currentPeriod, uint256 currentExitRatio) = reserve.recovery();
            assertEq(currentPrice, initialPrice);
            assertEq(currentPeriod, periodBefore);
            assertEq(currentExitRatio, exitDebtRatio);
        }
    }

    function swapOracle(bool useAlternate) external {
        MockOracle next = useAlternate ? alternateOracle : primaryOracle;
        reserve.setOracle(next);
        assertEq(address(reserve.oracle()), address(next));
    }

    function advanceAndCheckpoint(uint32 rawSeconds) external {
        vm.warp(block.timestamp + bound(uint256(rawSeconds), 1, 30 days));
        reserve.checkpointRecovery();
    }

    function withdrawalCount() external view returns (uint256) {
        return withdrawalEpochIds.length;
    }

    function _activeOracle() internal view returns (MockOracle) {
        return address(reserve.oracle()) == address(primaryOracle) ? primaryOracle : alternateOracle;
    }
}

contract NaNReserveInvariantTest is StdInvariant, Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal collateral;
    MockOracle internal oracle;
    MockOracle internal alternateOracle;
    NaNReserve internal reserve;
    NaNReserveHandler internal handler;
    address internal originalInf;

    function setUp() public {
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        alternateOracle = new MockOracle(3_100 * WAD);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_000, 6_450, 6_500, 10, 10);
        handler = new NaNReserveHandler(collateral, oracle, alternateOracle, reserve);

        collateral.mint(address(handler), 1_000_000 * WAD);
        handler.initialize();
        reserve.transferOwnership(address(handler));
        handler.acceptOwnership();
        originalInf = address(reserve.inf());

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.requestDefund.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.movePrice.selector;
        selectors[5] = handler.processWithdrawal.selector;
        selectors[6] = handler.advanceAndCheckpoint.selector;
        selectors[7] = handler.setDebtRatios.selector;
        selectors[8] = handler.setFees.selector;
        selectors[9] = handler.setWithdrawalDelay.selector;
        selectors[10] = handler.setWithdrawalEpoch.selector;
        selectors[11] = handler.setRecoveryHalvingPeriod.selector;
        selectors[12] = handler.swapOracle.selector;
        selectors[13] = handler.crash.selector;
        selectors[14] = handler.recover.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function testGovernanceChangesInterleavedWithCrashRecapitalizationAndWithdrawal() public {
        handler.setDebtRatios(5_000, 6_000, 7_000);
        handler.setFees(100, 200);
        handler.setWithdrawalDelay(uint32(7 days));
        handler.setWithdrawalEpoch(uint32(6 hours));
        handler.setRecoveryHalvingPeriod(uint32(2 days));
        handler.swapOracle(true);

        uint256 infBefore = reserve.inf().totalSupply();
        handler.fund(uint96(10 * WAD));
        assertGt(reserve.inf().totalSupply(), infBefore);
        uint256 debtBefore = reserve.debtUsd();
        handler.mint(uint96(10 * WAD));
        assertGt(reserve.debtUsd(), debtBefore);

        handler.requestDefund(uint96(10 * WAD));
        assertTrue(handler.hasWithdrawal());
        uint256 epoch = handler.lastWithdrawalEpoch();
        uint256 maturity = reserve.withdrawalMaturity(reserve.juniorSeries(), epoch);
        handler.setWithdrawalDelay(uint32(1 days));
        handler.setWithdrawalEpoch(uint32(1 hours));
        assertEq(reserve.withdrawalMaturity(reserve.juniorSeries(), epoch), maturity);

        handler.crash();
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Insolvent));
        uint256 infBeforeRecap = reserve.inf().totalSupply();
        handler.fund(uint96(10 * WAD));
        assertGt(reserve.inf().totalSupply(), infBeforeRecap);
        handler.advanceAndCheckpoint(uint32(2 days));
        handler.recover();
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Healthy));

        debtBefore = reserve.debtUsd();
        handler.redeem(uint96(100 * WAD));
        assertLt(reserve.debtUsd(), debtBefore);
        handler.processWithdrawal();
        assertFalse(handler.hasWithdrawal());
        invariantDebtAlwaysEqualsNanSupply();
        invariantClaimableWithdrawalCollateralIsNotReserveBacking();
        invariantExistingWithdrawalCohortsKeepTheirMaturity();
    }

    function invariantDebtAlwaysEqualsNanSupply() public view {
        assertEq(reserve.debtUsd(), reserve.nan().totalSupply());
    }

    function invariantInfAddressAndNamespaceNeverChange() public view {
        assertEq(address(reserve.inf()), originalInf);
        assertEq(reserve.juniorSeries(), 1);
    }

    function invariantIssuancePriceNeverBelowRealNavOrZero() public view {
        assertGe(reserve.fundingPriceUsd(), reserve.infPriceUsd());
        assertGt(reserve.fundingPriceUsd(), 0);
    }

    function invariantClaimableWithdrawalCollateralIsNotReserveBacking() public view {
        assertEq(
            reserve.reserveCollateral() + reserve.claimableWithdrawalCollateral(),
            collateral.balanceOf(address(reserve))
        );
    }

    function invariantOutstandingDebtAlwaysHasActiveJuniorCapital() public view {
        if (reserve.debtUsd() != 0) assertGt(reserve.inf().totalSupply(), 0);
    }

    function invariantHealthyStateRespectsConfiguredDebtRatio() public view {
        if (reserve.health() == NaNReserve.Health.Healthy) {
            assertLe(reserve.debtRatioBps(), reserve.maxDebtRatioBps());
            assertLe(reserve.debtUsd(), Math.mulDiv(reserve.reserveUsd(), reserve.maxDebtRatioBps(), 10_000));
        }
    }

    function invariantSeniorRedemptionPriceNeverExceedsOneDollar() public view {
        assertLe(reserve.nanRedemptionPriceUsd(), WAD);
    }

    function invariantReportedJuniorClaimsNeverExceedEquity() public view {
        INFToken activeInf = reserve.inf();
        uint256 supply = activeInf.totalSupply();
        if (supply != 0) {
            uint256 reportedClaims = Math.mulDiv(reserve.infPriceUsd(), supply, WAD);
            assertLe(reportedClaims, reserve.equityUsd());
        }
        assertEq(activeInf.reserve(), address(reserve));
    }

    function invariantInsolventSeniorClaimsDoNotExceedReserve() public view {
        if (reserve.health() == NaNReserve.Health.Insolvent) {
            uint256 claims = Math.mulDiv(reserve.nanRedemptionPriceUsd(), NaNToken(reserve.nan()).totalSupply(), WAD);
            assertLe(claims, reserve.reserveUsd());
        }
    }

    function invariantGovernanceConfigurationStaysWithinBounds() public view {
        assertEq(reserve.owner(), address(handler));
        assertGt(reserve.minDebtRatioBps(), 0);
        assertLt(reserve.minDebtRatioBps(), reserve.targetDebtRatioBps());
        assertLt(reserve.targetDebtRatioBps(), reserve.maxDebtRatioBps());
        assertLt(reserve.maxDebtRatioBps(), reserve.BPS());
        assertLe(reserve.mintFeeBps(), reserve.MAX_FEE_BPS());
        assertLe(reserve.redeemFeeBps(), reserve.MAX_FEE_BPS());
        assertGe(reserve.infWithdrawalDelay(), reserve.MIN_INF_WITHDRAWAL_DELAY());
        assertLe(reserve.infWithdrawalDelay(), reserve.MAX_INF_WITHDRAWAL_DELAY());
        assertGe(reserve.infWithdrawalEpoch(), reserve.MIN_INF_WITHDRAWAL_EPOCH());
        assertLe(reserve.infWithdrawalEpoch(), reserve.MAX_INF_WITHDRAWAL_EPOCH());
        assertGe(reserve.recoveryHalvingPeriod(), reserve.MIN_RECOVERY_HALVING_PERIOD());
        assertLe(reserve.recoveryHalvingPeriod(), reserve.MAX_RECOVERY_HALVING_PERIOD());
        address configuredOracle = address(reserve.oracle());
        assertTrue(configuredOracle == address(oracle) || configuredOracle == address(alternateOracle));
        assertGt(reserve.collateralPriceUsd(), 0);
    }

    function invariantExistingWithdrawalCohortsKeepTheirMaturity() public view {
        uint256 count = handler.withdrawalCount();
        for (uint256 i; i < count; ++i) {
            assertEq(
                reserve.withdrawalMaturity(reserve.juniorSeries(), handler.withdrawalEpochIds(i)),
                handler.withdrawalMaturities(i)
            );
        }
    }
}
