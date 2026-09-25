// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {NaNReserve} from "../src/NaNReserve.sol";
import {UniswapV3TwapOracle, IUniswapV3Factory, IUniswapV3PoolTwap} from "../src/UniswapV3TwapOracle.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";

/// @notice Environment-configured deployment with a direct Chainlink feed and Uniswap v3 TWAP fallback.
contract Deploy is Script {
    struct Config {
        uint256 deployerKey;
        address wstETH;
        address stEthUsdFeed;
        address weth;
        address usdc;
        address uniswapFactory;
        address wstEthWethPool;
        address wethUsdcPool;
        uint32 twapWindow;
        uint128 minWstEthWethLiquidity;
        uint128 minWethUsdcLiquidity;
        uint256 maxStaleness;
        uint256 fallbackPremiumBps;
        uint256 maxDebtRatioBps;
        uint256 mintFeeBps;
        uint256 redeemFeeBps;
    }

    function run() external returns (UniswapV3TwapOracle fallbackOracle, WstEthUsdOracle oracle, NaNReserve reserve) {
        Config memory config = _readConfig();

        vm.startBroadcast(config.deployerKey);
        fallbackOracle = _deployFallback(config);
        oracle = new WstEthUsdOracle(
            IWstETH(config.wstETH),
            IAggregatorV3(config.stEthUsdFeed),
            fallbackOracle,
            config.maxStaleness,
            config.fallbackPremiumBps
        );
        reserve = new NaNReserve(
            IERC20(config.wstETH), oracle, config.maxDebtRatioBps, config.mintFeeBps, config.redeemFeeBps
        );
        vm.stopBroadcast();

        console2.log("WstEthUsdOracle", address(oracle));
        console2.log("Primary stETH/USD feed", config.stEthUsdFeed);
        console2.log("UniswapV3TwapOracle", address(fallbackOracle));
        console2.log("NaNReserve", address(reserve));
        console2.log("NaNToken", address(reserve.nan()));
        console2.log("INFToken series 1", address(reserve.inf()));
    }

    function _readConfig() internal view returns (Config memory config) {
        config.deployerKey = vm.envUint("PRIVATE_KEY");
        config.wstETH = vm.envAddress("WSTETH");
        config.stEthUsdFeed = vm.envAddress("STETH_USD_FEED");
        config.weth = vm.envAddress("WETH");
        config.usdc = vm.envAddress("USDC");
        config.uniswapFactory = vm.envAddress("UNISWAP_V3_FACTORY");
        config.wstEthWethPool = vm.envAddress("WSTETH_WETH_POOL");
        config.wethUsdcPool = vm.envAddress("WETH_USDC_POOL");
        config.twapWindow = SafeCast.toUint32(vm.envUint("TWAP_WINDOW"));
        config.minWstEthWethLiquidity = SafeCast.toUint128(vm.envUint("MIN_WSTETH_WETH_HARMONIC_LIQUIDITY"));
        config.minWethUsdcLiquidity = SafeCast.toUint128(vm.envUint("MIN_WETH_USDC_HARMONIC_LIQUIDITY"));
        config.maxStaleness = vm.envOr("MAX_STALENESS", uint256(1 hours));
        config.fallbackPremiumBps = vm.envOr("FALLBACK_PREMIUM_BPS", uint256(200));
        config.maxDebtRatioBps = vm.envOr("MAX_DEBT_RATIO_BPS", uint256(6_500));
        config.mintFeeBps = vm.envOr("MINT_FEE_BPS", uint256(10));
        config.redeemFeeBps = vm.envOr("REDEEM_FEE_BPS", uint256(10));
    }

    function _deployFallback(Config memory config) internal returns (UniswapV3TwapOracle fallbackOracle) {
        fallbackOracle = new UniswapV3TwapOracle(
            config.wstETH,
            config.weth,
            config.usdc,
            IUniswapV3Factory(config.uniswapFactory),
            IUniswapV3PoolTwap(config.wstEthWethPool),
            IUniswapV3PoolTwap(config.wethUsdcPool),
            config.twapWindow,
            config.minWstEthWethLiquidity,
            config.minWethUsdcLiquidity
        );
    }
}
