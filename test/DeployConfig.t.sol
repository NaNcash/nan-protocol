// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployConfigHarness is Deploy {
    function readConfig() external view returns (Config memory) {
        return _readConfig();
    }
}

contract DeployConfigTest is Test {
    DeployConfigHarness internal deploy;

    function setUp() public {
        deploy = new DeployConfigHarness();
        // Synthetic test configuration only; no broadcast or external contracts.
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("WSTETH", vm.toString(address(1)));
        vm.setEnv("STETH_USD_FEED", vm.toString(address(2)));
        vm.setEnv("WETH", vm.toString(address(3)));
        vm.setEnv("USDC", vm.toString(address(4)));
        vm.setEnv("UNISWAP_V3_FACTORY", vm.toString(address(5)));
        vm.setEnv("WSTETH_WETH_POOL", vm.toString(address(6)));
        vm.setEnv("WETH_USDC_POOL", vm.toString(address(7)));
        vm.setEnv("TWAP_WINDOW", "3600");
        vm.setEnv("MIN_WSTETH_WETH_HARMONIC_LIQUIDITY", "1");
        vm.setEnv("MIN_WETH_USDC_HARMONIC_LIQUIDITY", "1");
        vm.setEnv("AUTHORIZER", vm.toString(address(8)));
    }

    function testRequiresExplicitNonzeroFreshness() public {
        // Foundry environment changes are process-wide: keep these checks in one test
        // without fuzzing so parallel tests/cases cannot overwrite the age mid-read.
        vm.setEnv("MAX_STALENESS", "");
        vm.expectRevert();
        deploy.readConfig();
        vm.setEnv("MAX_STALENESS", "0");
        vm.expectRevert(Deploy.InvalidMaxStaleness.selector);
        deploy.readConfig();
        vm.setEnv("MAX_STALENESS", "4500");
        Deploy.Config memory config = deploy.readConfig();
        assertEq(config.maxStaleness, 75 minutes);
        vm.setEnv("MAX_STALENESS", "90000");
        config = deploy.readConfig();
        assertEq(config.maxStaleness, 90_000);
    }
}
