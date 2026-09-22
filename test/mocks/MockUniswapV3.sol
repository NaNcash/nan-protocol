// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3Factory, IUniswapV3PoolTwap} from "../../src/UniswapV3TwapOracle.sol";

contract MockUniswapV3Factory is IUniswapV3Factory {
    mapping(bytes32 => address) internal pools;

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(token0, token1, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(tokenA, tokenB, fee))];
    }
}

contract MockUniswapV3Pool is IUniswapV3PoolTwap {
    error NotEnoughHistory();
    error PoolUnavailable();

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint128 public liquidity;
    uint128 public historicalLiquidity;
    int24 public meanTick;
    uint32 public availableHistory = 1 days;
    bool public unavailable;
    bool public malformedObservation;

    constructor(address factory_, address token0_, address token1_, uint24 fee_, int24 meanTick_, uint128 liquidity_) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        meanTick = meanTick_;
        liquidity = liquidity_;
        historicalLiquidity = liquidity_;
    }

    function setLiquidity(uint128 historical, uint128 current) external {
        historicalLiquidity = historical;
        liquidity = current;
    }

    function setMeanTick(int24 tick) external {
        meanTick = tick;
    }

    function setAvailableHistory(uint32 window) external {
        availableHistory = window;
    }

    function setUnavailable(bool unavailable_) external {
        unavailable = unavailable_;
    }

    function setMalformedObservation(bool malformed_) external {
        malformedObservation = malformed_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (unavailable) revert PoolUnavailable();
        if (secondsAgos[0] > availableHistory) revert NotEnoughHistory();
        if (malformedObservation) return (new int56[](1), new uint160[](1));

        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        tickCumulatives[1] = SafeCast.toInt56(int256(meanTick) * int256(uint256(secondsAgos[0])));
        if (historicalLiquidity != 0) {
            secondsPerLiquidityCumulativeX128s[1] =
                SafeCast.toUint160(Math.mulDiv(uint256(secondsAgos[0]), 1 << 128, historicalLiquidity));
        }
    }
}
