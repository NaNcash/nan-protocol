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
    MockOracle public immutable oracle;
    NaNReserve public immutable reserve;

    constructor(MockERC20 collateral_, MockOracle oracle_, NaNReserve reserve_) {
        collateral = collateral_;
        oracle = oracle_;
        reserve = reserve_;
        collateral.approve(address(reserve_), type(uint256).max);
    }

    function initialize() external {
        reserve.fund(100 * WAD, 0, address(this));
        reserve.mint(180 * WAD, 0, address(this));
    }

    function fund(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e12, 100 * WAD);
        try reserve.fund(amount, 0, address(this)) {} catch {}
    }

    function mint(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e12, 100 * WAD);
        try reserve.mint(amount, 0, address(this)) {} catch {}
    }

    function defund(uint96 rawAmount) external {
        uint256 balance = reserve.inf().balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        try reserve.defund(amount, 0, address(this)) {} catch {}
    }

    function redeem(uint96 rawAmount) external {
        uint256 balance = reserve.nan().balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        try reserve.redeem(amount, 0, address(this)) {} catch {}
    }

    function recapitalize(uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1e12, 500 * WAD);
        try reserve.recapitalize(amount, 0, address(this)) {} catch {}
    }

    function movePrice(uint96 rawPrice) external {
        oracle.setPrice(bound(uint256(rawPrice), 100 * WAD, 6_000 * WAD));
    }
}

contract NaNReserveInvariantTest is StdInvariant, Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal collateral;
    MockOracle internal oracle;
    NaNReserve internal reserve;
    NaNReserveHandler internal handler;

    function setUp() public {
        collateral = new MockERC20("Wrapped stETH", "wstETH");
        oracle = new MockOracle(3_000 * WAD);
        reserve = new NaNReserve(collateral, oracle, 6_500, 10, 10);
        handler = new NaNReserveHandler(collateral, oracle, reserve);

        collateral.mint(address(handler), 1_000_000 * WAD);
        handler.initialize();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.defund.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.recapitalize.selector;
        selectors[5] = handler.movePrice.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantDebtAlwaysEqualsNanSupply() public view {
        assertEq(reserve.debtUsd(), reserve.nan().totalSupply());
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
}
