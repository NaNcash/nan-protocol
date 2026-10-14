// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {PlaygroundETH} from "../src/playground/PlaygroundETH.sol";
import {PlaygroundPriceFeed} from "../src/playground/PlaygroundPriceFeed.sol";
import {PlaygroundFallbackOracle} from "../src/playground/PlaygroundFallbackOracle.sol";

/// @notice Sepolia-only demo deployment; all collateral and USD prices are simulated.
contract DeploySepolia is Script {
    error WrongChain();
    error MissingDeployer();
    error PublicDevelopmentAccount();

    function run()
        external
        returns (
            PlaygroundETH collateral,
            PlaygroundPriceFeed feed,
            PlaygroundFallbackOracle fallbackOracle,
            WstEthUsdOracle oracle,
            NaNReserve reserve
        )
    {
        if (block.chainid != 11155111) revert WrongChain();
        address deployer = vm.envOr("SEPOLIA_DEPLOYER", address(0));
        if (deployer == address(0)) {
            address[] memory wallets = vm.getWallets();
            if (wallets.length != 1) revert MissingDeployer();
            deployer = wallets[0];
        }
        _checkDeployer(deployer);
        address controller = vm.envOr("SEPOLIA_AUTHORIZER", deployer);

        vm.startBroadcast(deployer);
        collateral = new PlaygroundETH(controller);
        feed = new PlaygroundPriceFeed(controller);
        fallbackOracle = new PlaygroundFallbackOracle(controller);
        oracle = new WstEthUsdOracle(
            IWstETH(address(collateral)), IAggregatorV3(address(feed)), fallbackOracle, 1 hours, 200
        );
        reserve = new NaNReserve(collateral, oracle, controller, 3_000, 5_500, 6_500, 10, 10);

        // Bootstrap INF backing with free collateral so visitors can mint NaN immediately.
        collateral.faucet(100 ether);
        collateral.approve(address(reserve), 100 ether);
        reserve.fund(100 ether, 300_000 ether, deployer);
        vm.stopBroadcast();

        console2.log("Playground ETH", address(collateral));
        console2.log("Simulated USD feed", address(feed));
        console2.log("Diagnostic fallback", address(fallbackOracle));
        console2.log("Oracle router", address(oracle));
        console2.log("NaN reserve", address(reserve));
        console2.log("NaN token", address(reserve.nan()));
        console2.log("INF token", address(reserve.inf()));
        console2.log("Controller", controller);
        console2.log("Initial INF holder", deployer);
    }

    function _checkDeployer(address deployer) internal pure {
        address[10] memory publicAccounts = [
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
            0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,
            0x976EA74026E726554dB657fA54763abd0C3a0aa9,
            0x14dC79964da2C08b23698B3D3cc7Ca32193d9955,
            0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f,
            0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
        ];
        for (uint256 i; i < publicAccounts.length; ++i) {
            if (deployer == publicAccounts[i]) revert PublicDevelopmentAccount();
        }
    }
}
