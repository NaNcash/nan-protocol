// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {NaNToken} from "../src/NaNToken.sol";
import {INFToken} from "../src/INFToken.sol";

contract NaNReserveTest is TestBase {
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
        reserve = new NaNReserve(wstETH, oracle, 6_500, 10, 10); // 65% max debt ratio, 10 bps each way
        nan = reserve.nan();
        inf = reserve.inf();

        wstETH.mint(ALICE, 1_000 * WAD);
        wstETH.mint(BOB, 1_000 * WAD);

        vm.prank(ALICE);
        wstETH.approve(address(reserve), type(uint256).max);
        vm.prank(BOB);
        wstETH.approve(address(reserve), type(uint256).max);
    }

    function _bootstrap() internal {
        vm.prank(ALICE);
        reserve.fund(100 * WAD, 0, ALICE); // $300k junior capital
    }

    function _bootstrapAndMint() internal {
        _bootstrap();
        vm.prank(BOB);
        reserve.mint(180 * WAD, 0, BOB); // $540k collateral -> 539,460 NaN after 10 bps fee
    }

    function testInitialFundingStartsInfAtOneDollar() public {
        _bootstrap();
        assertEq(inf.balanceOf(ALICE), 300_000 * WAD, "wrong bootstrap INF amount");
        assertEq(reserve.infPriceUsd(), WAD, "INF should bootstrap at $1");
    }

    function testMintRespectsDebtRatio() public {
        _bootstrapAndMint();
        assertEq(nan.balanceOf(BOB), 539_460 * WAD, "wrong NaN output");
        assertLe(reserve.debtRatioBps(), 6_500, "debt ratio exceeded limit");
    }

    function testMintTooLargeReverts() public {
        _bootstrap();
        vm.prank(BOB);
        vm.expectRevert(NaNReserve.DebtRatioTooHigh.selector);
        reserve.mint(200 * WAD, 0, BOB);
    }

    function testWstEthYieldAccruesToInf() public {
        _bootstrapAndMint();
        uint256 infPriceBefore = reserve.infPriceUsd();

        oracle.setPrice(3_030 * WAD); // model ~1% wstETH appreciation
        uint256 infPriceAfter = reserve.infPriceUsd();

        assertGt(infPriceAfter, infPriceBefore, "staking yield should accrue to INF");
        assertEq(nan.totalSupply(), 539_460 * WAD, "NaN liability should not rebase");
    }

    function testDefundCannotBreakCollateralLimit() public {
        _bootstrapAndMint();

        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.DebtRatioTooHigh.selector);
        reserve.defund(20_000 * WAD, 0, ALICE);

        vm.prank(ALICE);
        reserve.defund(5_000 * WAD, 0, ALICE);
        assertLe(reserve.debtRatioBps(), 6_500, "defund broke debt-ratio limit");
    }

    function testHealthyRedemptionLeavesFeeForInf() public {
        _bootstrapAndMint();
        uint256 infPriceBefore = reserve.infPriceUsd();

        vm.prank(BOB);
        reserve.redeem(10_000 * WAD, 0, BOB);

        uint256 infPriceAfter = reserve.infPriceUsd();
        assertGt(infPriceAfter, infPriceBefore, "redeem fee should accrue to INF");
        assertLt(reserve.debtRatioBps(), 6_500, "redemption should improve health");
    }

    function testInsolventRedemptionIsProRataAndFeeFree() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD); // reserve is now below NaN liabilities

        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Insolvent), "expected insolvency");
        uint256 ratioBefore = reserve.collateralRatio();

        uint256 bobBefore = wstETH.balanceOf(BOB);
        vm.prank(BOB);
        reserve.redeem(10_000 * WAD, 0, BOB);
        uint256 received = wstETH.balanceOf(BOB) - bobBefore;

        assertGt(received, 0, "redemption returned nothing");
        assertApproxEqAbs(reserve.collateralRatio(), ratioBefore, 1e12, "pro-rata redemption changed solvency materially");
    }

    function testInsolventFundingIsExplicitlyNotYetImplemented() public {
        _bootstrapAndMint();
        oracle.setPrice(1_500 * WAD);

        vm.prank(ALICE);
        vm.expectRevert(NaNReserve.InsolventFundingNotImplemented.selector);
        reserve.fund(10 * WAD, 0, ALICE);
    }
}
