// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";

/// @notice Environment-configured deployment with wstETH, a direct Chainlink feed, and a vetted fallback oracle.
contract Deploy is Script {
    function run() external returns (WstEthUsdOracle oracle, NaNReserve reserve) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address wstETH = vm.envAddress("WSTETH");
        address stEthUsdFeed = vm.envAddress("STETH_USD_FEED");
        address fallbackOracle = vm.envAddress("FALLBACK_ORACLE");
        uint256 maxStaleness = vm.envOr("MAX_STALENESS", uint256(1 hours));
        uint256 fallbackPremiumBps = vm.envOr("FALLBACK_PREMIUM_BPS", uint256(200));
        uint256 maxDebtRatioBps = vm.envOr("MAX_DEBT_RATIO_BPS", uint256(6_500));
        uint256 mintFeeBps = vm.envOr("MINT_FEE_BPS", uint256(10));
        uint256 redeemFeeBps = vm.envOr("REDEEM_FEE_BPS", uint256(10));

        vm.startBroadcast(deployerKey);
        oracle = new WstEthUsdOracle(
            IWstETH(wstETH), IAggregatorV3(stEthUsdFeed), IPriceOracle(fallbackOracle), maxStaleness, fallbackPremiumBps
        );
        reserve = new NaNReserve(IERC20(wstETH), oracle, maxDebtRatioBps, mintFeeBps, redeemFeeBps);
        vm.stopBroadcast();

        console2.log("WstEthUsdOracle", address(oracle));
        console2.log("Primary stETH/USD feed", stEthUsdFeed);
        console2.log("Fallback wstETH/USD oracle", fallbackOracle);
        console2.log("NaNReserve", address(reserve));
        console2.log("NaNToken", address(reserve.nan()));
        console2.log("INFToken series 1", address(reserve.inf()));
    }
}
