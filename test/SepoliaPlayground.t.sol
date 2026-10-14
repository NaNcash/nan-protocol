// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeploySepolia} from "../script/DeploySepolia.s.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {WstEthUsdOracle} from "../src/WstEthUsdOracle.sol";
import {PlaygroundETH} from "../src/playground/PlaygroundETH.sol";
import {PlaygroundPriceFeed} from "../src/playground/PlaygroundPriceFeed.sol";
import {PlaygroundFallbackOracle} from "../src/playground/PlaygroundFallbackOracle.sol";
import {SepoliaOnly} from "../src/playground/SepoliaOnly.sol";

contract SepoliaPlaygroundTest is Test {
    uint256 internal constant DEPLOYER_KEY = 123;
    address internal controller;
    address internal alice;
    PlaygroundETH internal collateral;
    PlaygroundPriceFeed internal feed;
    PlaygroundFallbackOracle internal fallbackOracle;
    WstEthUsdOracle internal oracle;
    NaNReserve internal reserve;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(10 days);
        controller = vm.addr(DEPLOYER_KEY);
        alice = makeAddr("alice");
        vm.setEnv("SEPOLIA_DEPLOYER", vm.toString(controller));
        vm.setEnv("SEPOLIA_AUTHORIZER", vm.toString(controller));
        (collateral, feed, fallbackOracle, oracle, reserve) = new DeploySepolia().run();
    }

    function testDeploymentSeedsUsableReserveAndAssignsController() public {
        assertEq(reserve.owner(), controller);
        assertEq(collateral.owner(), controller);
        assertEq(feed.owner(), controller);
        assertEq(fallbackOracle.owner(), controller);
        assertEq(address(reserve.collateral()), address(collateral));
        assertEq(address(reserve.oracle()), address(oracle));
        assertEq(reserve.reserveCollateral(), 100 ether);
        assertEq(reserve.inf().balanceOf(controller), 300_000 ether);
        assertEq(collateral.allowance(controller, address(reserve)), 0);
        assertEq(reserve.debtUsd(), 0);
        vm.startPrank(alice);
        collateral.faucet(180 ether);
        collateral.approve(address(reserve), 180 ether);
        reserve.mint(180 ether, 539_460 ether, alice);
        vm.stopPrank();
        assertEq(reserve.nan().balanceOf(alice), 539_460 ether);
    }

    function testSeparateAuthorizerKeepsBootstrapInfWithDeployer() public {
        vm.setEnv("SEPOLIA_AUTHORIZER", vm.toString(alice));
        (PlaygroundETH token, PlaygroundPriceFeed primary, PlaygroundFallbackOracle fallback_,, NaNReserve stack) =
            new DeploySepolia().run();
        assertEq(stack.owner(), alice);
        assertEq(token.owner(), alice);
        assertEq(primary.owner(), alice);
        assertEq(fallback_.owner(), alice);
        assertEq(stack.inf().balanceOf(controller), 300_000 ether);
    }

    function testPublicDevelopmentDeployerRejectedBeforeBroadcast() public {
        DeploySepoliaHarness deployScript = new DeploySepoliaHarness();
        vm.expectRevert(DeploySepolia.PublicDevelopmentAccount.selector);
        deployScript.checkDeployer(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    }

    function testVisitorsCannotChangeSharedScenarios() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(unauthorized);
        collateral.setStEthPerToken(2 ether);
        vm.expectRevert(unauthorized);
        feed.setAnswer(1_500e8);
        vm.expectRevert(unauthorized);
        feed.setStale(true);
        vm.expectRevert(unauthorized);
        feed.setUnavailable(true);
        vm.expectRevert(unauthorized);
        fallbackOracle.setPrice(0);
        vm.expectRevert(unauthorized);
        reserve.setInfWithdrawalDelay(1 days);
        vm.stopPrank();
    }

    function testFuzzFaucetSupportsRepeatedFreeCollateral(uint256 amount) public {
        amount = bound(amount, 1e6, collateral.MAX_FAUCET_AMOUNT());
        vm.startPrank(alice);
        collateral.faucet(amount);
        collateral.faucet(amount);
        collateral.approve(address(reserve), amount);
        reserve.fund(amount, reserve.previewFund(amount), alice);
        vm.stopPrank();
        assertEq(collateral.balanceOf(alice), amount);
        assertEq(reserve.reserveCollateral(), 100 ether + amount);
    }

    function testFaucetAndRateRejectInvalidAmounts() public {
        vm.expectRevert(PlaygroundETH.InvalidFaucetAmount.selector);
        collateral.faucet(0);
        vm.expectRevert(PlaygroundETH.InvalidFaucetAmount.selector);
        collateral.faucet(1_001 ether);
        vm.expectRevert(PlaygroundETH.InvalidFaucetAmount.selector);
        collateral.faucet(type(uint256).max);
        vm.prank(controller);
        vm.expectRevert(PlaygroundETH.InvalidRate.selector);
        collateral.setStEthPerToken(0);
    }

    function testFuzzAllPlaygroundDeploymentsRejectOtherChains(uint64 chainId) public {
        vm.assume(chainId != 11155111);
        vm.chainId(chainId);
        vm.expectRevert(SepoliaOnly.WrongChain.selector);
        new PlaygroundETH(controller);
        vm.expectRevert(SepoliaOnly.WrongChain.selector);
        new PlaygroundPriceFeed(controller);
        vm.expectRevert(SepoliaOnly.WrongChain.selector);
        new PlaygroundFallbackOracle(controller);
        DeploySepolia deployScript = new DeploySepolia();
        vm.expectRevert(DeploySepolia.WrongChain.selector);
        deployScript.run();
    }

    function testPrimaryOutagesHaltPayoutsDespiteHealthyDiagnosticFallback() public {
        vm.startPrank(alice);
        collateral.faucet(180 ether);
        collateral.approve(address(reserve), 180 ether);
        reserve.mint(180 ether, 539_460 ether, alice);
        vm.stopPrank();
        vm.prank(controller);
        feed.setStale(true);
        vm.prank(alice);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        reserve.redeem(1_000 ether, 0, alice);
        (uint256 price, bool fallbackUsed) = oracle.redemptionPrice();
        assertEq(price, 3_060 ether);
        assertTrue(fallbackUsed);
        vm.startPrank(controller);
        feed.setStale(false);
        feed.setUnavailable(true);
        vm.stopPrank();
        vm.expectRevert(PlaygroundPriceFeed.FeedUnavailable.selector);
        reserve.collateralPriceUsd();
        vm.prank(controller);
        feed.setUnavailable(false);
        vm.warp(block.timestamp + 30 days);
        assertEq(reserve.collateralPriceUsd(), 3_000 ether);
        vm.prank(alice);
        assertGt(reserve.redeem(1_000 ether, 0, alice), 0);
    }

    function testLifecycleRecoveryAndRealTimeWithdrawal() public {
        vm.startPrank(alice);
        collateral.faucet(500 ether);
        collateral.approve(address(reserve), 290 ether);
        reserve.fund(100 ether, reserve.previewFund(100 ether), alice);
        reserve.mint(180 ether, 539_460 ether, alice);
        vm.stopPrank();
        vm.prank(controller);
        feed.setAnswer(1_000e8);
        reserve.checkpointRecovery();
        assertEq(uint256(reserve.health()), uint256(NaNReserve.Health.Insolvent));
        uint256 quote = reserve.previewFund(10 ether);
        vm.prank(alice);
        reserve.fund(10 ether, quote, alice);
        vm.prank(controller);
        feed.setAnswer(4_000e8);
        reserve.checkpointRecovery();
        vm.startPrank(alice);
        reserve.inf().approve(address(reserve), 1_000 ether);
        (uint256 series, uint256 epoch) = reserve.requestDefund(1_000 ether);
        vm.stopPrank();
        uint256 maturity = reserve.withdrawalMaturity(series, epoch);
        vm.warp(maturity);
        reserve.settleDefundEpoch(series, epoch);
        vm.prank(alice);
        (uint256 payout,) = reserve.claimDefund(series, epoch, 0, alice);
        assertGt(payout, 0);
    }
}

contract DeploySepoliaHarness is DeploySepolia {
    function checkDeployer(address deployer) external pure {
        _checkDeployer(deployer);
    }
}
