// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {MathLib} from "./libraries/MathLib.sol";

interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Minimal wstETH/USD oracle for the NaN prototype.
/// @dev Values wstETH as ETH/USD * stETH-per-wstETH. This assumes stETH is economically redeemable near 1 ETH.
///      A production oracle should add a conservative stETH/ETH market-price/depeg guard.
contract WstEthUsdOracle is IPriceOracle {
    using MathLib for uint256;

    error InvalidPrice();
    error StalePrice();
    error InvalidRound();

    uint256 public constant WAD = 1e18;

    IWstETH public immutable wstETH;
    IAggregatorV3 public immutable ethUsdFeed;
    uint256 public immutable maxStaleness;
    uint8 public immutable feedDecimals;

    constructor(IWstETH wstETH_, IAggregatorV3 ethUsdFeed_, uint256 maxStaleness_) {
        wstETH = wstETH_;
        ethUsdFeed = ethUsdFeed_;
        maxStaleness = maxStaleness_;
        feedDecimals = ethUsdFeed_.decimals();
    }

    function price() external view returns (uint256 wstEthUsd) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert InvalidPrice();
        if (answeredInRound < roundId) revert InvalidRound();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();

        uint256 ethUsd = uint256(answer);
        if (feedDecimals < 18) {
            ethUsd *= 10 ** (18 - feedDecimals);
        } else if (feedDecimals > 18) {
            ethUsd /= 10 ** (feedDecimals - 18);
        }

        wstEthUsd = MathLib.mulDivDown(ethUsd, wstETH.stEthPerToken(), WAD);
        if (wstEthUsd == 0) revert InvalidPrice();
    }
}
