// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract WithdrawalCapacityTest is Test {
    uint256 internal constant WAD = 1e18;
    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;

    function setUp() public {
        vm.warp(10 days);
        collateral = new MockERC20("Collateral", "COL");
        oracle = new MockOracle(3 * WAD + 7);
        reserve = new NaNReserve(collateral, oracle, address(this), 5_500, 6_500, 0, 0);
        collateral.mint(address(this), 100 * WAD);
        collateral.approve(address(reserve), 100 * WAD);
        reserve.fund(WAD, 0, address(this));
        reserve.inf().approve(address(reserve), type(uint256).max);
    }

    function _mintDebtAndMinimumBacking() internal returns (uint256 minimum) {
        reserve.mint(WAD, 0, address(this));
        uint256 minimumUsd = Math.mulDiv(reserve.debtUsd(), 10_000, 5_500, Math.Rounding.Ceil);
        minimum = Math.mulDiv(minimumUsd, WAD, oracle.price(), Math.Rounding.Ceil);
        // This boundary requires rounding both the USD requirement and collateral.
        assertGt(mulmod(reserve.debtUsd(), 10_000, 5_500), 0);
        assertGt(mulmod(minimumUsd, WAD, oracle.price()), 0);
        assertGe(Math.mulDiv(minimum, oracle.price(), WAD), minimumUsd);
        assertLt(Math.mulDiv(minimum - 1, oracle.price(), WAD), minimumUsd);
    }

    function testCapacityAtAdjacentTargetBackingBoundaries() public {
        uint256 minimum = _mintDebtAndMinimumBacking();
        (uint256 series, uint256 epoch) = reserve.requestDefund(reserve.inf().totalSupply());
        vm.warp(reserve.withdrawalMaturity(series, epoch));

        for (uint256 i; i < 3; ++i) {
            deal(address(collateral), address(reserve), minimum - 1 + i);
            assertEq(reserve.maxDefundableUsd(), i < 2 ? 0 : oracle.price() / WAD);
            // One available collateral wei can still be unexecutable after INF/USD rounding.
            vm.expectRevert(NaNReserve.NoWithdrawalCapacity.selector);
            reserve.settleDefundEpoch(series, epoch);
            assertEq(reserve.claimableWithdrawalCollateral(), 0);
        }
    }

    function testReportedCapacityExcludesCollateralRoundingSurplus() public {
        uint256 minimum = _mintDebtAndMinimumBacking();
        deal(address(collateral), address(reserve), minimum + WAD);
        uint256 capacity = reserve.maxDefundableUsd();
        assertEq(capacity, oracle.price());
        uint256 supply = reserve.inf().totalSupply();
        uint256 equity = reserve.equityUsd();
        (uint256 series, uint256 epoch) = reserve.requestDefund(supply);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filled, uint256 payout,,) = reserve.withdrawalEpochs(series, epoch);
        assertGt(filled, 0);
        assertLt(filled, supply);
        assertLe(payout, WAD);
        assertLe(Math.mulDiv(payout, oracle.price(), WAD), capacity);
        assertGe(reserve.reserveCollateral(), minimum);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertEq(collateral.balanceOf(address(reserve)), reserve.reserveCollateral() + payout);
        assertEq(reserve.inf().totalSupply() + filled, supply);
        // The helper is a capacity bound, not an exact fill promise. The gap is
        // bounded by one INF base unit, one USD base unit, and collateral rounding.
        uint256 gapBound = Math.ceilDiv(equity, supply) + Math.ceilDiv(oracle.price(), WAD) + 1;
        assertLe(capacity - Math.mulDiv(payout, oracle.price(), WAD), gapBound);
    }

    function testDebtFreeCapacityUsesCollateralValueAndSettlementNeedsNoOracle() public {
        assertEq(reserve.maxDefundableUsd(), oracle.price());
        (uint256 series, uint256 epoch) = reserve.requestDefund(reserve.inf().totalSupply());
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        oracle.setPrice(0);
        reserve.settleDefundEpoch(series, epoch);
        (uint256 payout, uint256 refund) = reserve.claimDefund(series, epoch, WAD, address(this));
        assertEq(payout, WAD);
        assertEq(refund, 0);
        assertEq(reserve.reserveCollateral(), 0);
    }

    function testZeroCapacityAtExtremeLowPriceDoesNotOverflowCollateralConversion() public {
        reserve.mint(WAD, 0, address(this));
        oracle.setPrice(1);
        assertEq(reserve.maxDefundableUsd(), 0);
    }

    function testFuzzCapacityBoundsSettlement(uint96 rawPrice, uint96 rawSurplus) public {
        reserve.mint(WAD, 0, address(this));
        uint256 price = bound(uint256(rawPrice), WAD / 2, 10_000 * WAD);
        oracle.setPrice(price);
        uint256 minimumUsd = Math.mulDiv(reserve.debtUsd(), 10_000, 5_500, Math.Rounding.Ceil);
        uint256 minimum = Math.mulDiv(minimumUsd, WAD, price, Math.Rounding.Ceil);
        uint256 surplus = bound(uint256(rawSurplus), 1e12, WAD);
        deal(address(collateral), address(reserve), minimum + surplus);
        uint256 capacity = reserve.maxDefundableUsd();
        assertEq(capacity, Math.mulDiv(surplus, price, WAD));

        uint256 supply = reserve.inf().totalSupply();
        uint256 equity = reserve.equityUsd();
        (uint256 series, uint256 epoch) = reserve.requestDefund(supply);
        vm.warp(reserve.withdrawalMaturity(series, epoch));
        reserve.settleDefundEpoch(series, epoch);
        (,, uint256 filled, uint256 payout,,) = reserve.withdrawalEpochs(series, epoch);
        assertLe(payout, surplus);
        assertGt(payout, 0);
        assertGe(reserve.reserveCollateral(), minimum);
        assertLe(reserve.debtRatioBps(), reserve.targetDebtRatioBps());
        assertEq(collateral.balanceOf(address(reserve)), reserve.reserveCollateral() + payout);
        assertEq(reserve.inf().totalSupply() + filled, supply);
        uint256 gapBound = Math.ceilDiv(equity, supply) + Math.ceilDiv(price, WAD) + 1;
        uint256 payoutUsd = Math.mulDiv(payout, price, WAD);
        assertLe(payoutUsd, capacity);
        assertLe(capacity - payoutUsd, gapBound);
    }
}
