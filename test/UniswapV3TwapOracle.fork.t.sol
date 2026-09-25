// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TwapOracle, IUniswapV3Factory, IUniswapV3PoolTwap} from "../src/UniswapV3TwapOracle.sol";

contract UniswapV3TwapOracleForkTest is Test {
    function testEthereumMainnetCandidatePools() public {
        string memory rpcUrl = vm.envOr("NAN_MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpcUrl);
        UniswapV3TwapOracle oracle = new UniswapV3TwapOracle(
            0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984),
            IUniswapV3PoolTwap(0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa),
            IUniswapV3PoolTwap(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640),
            1 hours,
            1e24,
            1e18
        );

        uint256 wstEthUsd = oracle.price();
        assertGt(wstEthUsd, 100e18);
        assertLt(wstEthUsd, 100_000e18);
    }
}
