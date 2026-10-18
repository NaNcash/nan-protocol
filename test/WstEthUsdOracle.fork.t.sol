// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WstEthUsdOracle, IWstETH, IAggregatorV3} from "../src/WstEthUsdOracle.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract WstEthUsdOracleForkTest is Test {
    function testEthereumMainnetReferenceFreshnessPolicy() public {
        string memory rpcUrl = vm.envOr("NAN_MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);
        IAggregatorV3 feed = IAggregatorV3(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8);
        IWstETH wrapper = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        assertEq(feed.decimals(), 8);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertGt(roundId, 0);
        assertGe(answeredInRound, roundId);
        assertGt(answer, 0);
        assertGt(updatedAt, 0);
        assertLe(updatedAt, block.timestamp);
        assertLe(block.timestamp - updatedAt, 75 minutes);

        WstEthUsdOracle oracle = new WstEthUsdOracle(wrapper, feed, new MockOracle(3_000e18), 75 minutes, 200);
        uint256 price = oracle.price();
        assertGt(price, 0);
        vm.warp(updatedAt + 75 minutes);
        assertEq(oracle.price(), price);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(WstEthUsdOracle.StalePrice.selector);
        oracle.price();
    }
}
