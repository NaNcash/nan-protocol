// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {LocalWstETH} from "../src/local/LocalWstETH.sol";
import {LocalStEthUsdFeed} from "../src/local/LocalStEthUsdFeed.sol";
import {LocalFallbackOracle} from "../src/local/LocalFallbackOracle.sol";

/// @notice Deploys a full NaN stack backed by deliberately unsafe local mocks.
contract DeployLocal is Script {
    error WrongChain();

    function run()
        external
        returns (
            LocalWstETH collateral,
            LocalStEthUsdFeed feed,
            LocalFallbackOracle fallbackOracle,
            WstEthUsdOracle oracle,
            NaNReserve reserve
        )
    {
        if (block.chainid != 31337) revert WrongChain();
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        collateral = new LocalWstETH();
        feed = new LocalStEthUsdFeed();
        fallbackOracle = new LocalFallbackOracle();
        oracle = new WstEthUsdOracle(
            IWstETH(address(collateral)), IAggregatorV3(address(feed)), fallbackOracle, 1 hours, 200
        );
        reserve = new NaNReserve(collateral, oracle, vm.addr(deployerKey), 3_000, 5_500, 6_500, 10, 10);
        vm.stopBroadcast();

        console2.log("Local wstETH", address(collateral));
        console2.log("Local stETH/USD feed", address(feed));
        console2.log("Local fallback", address(fallbackOracle));
        console2.log("Real oracle router", address(oracle));
        console2.log("Real NaN reserve", address(reserve));
        console2.log("NaN token", address(reserve.nan()));
        console2.log("INF token", address(reserve.inf()));
    }
}
