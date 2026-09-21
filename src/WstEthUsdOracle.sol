// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

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

/// @notice Conservative wstETH/USD oracle using Chainlink-compatible ETH/USD and stETH/ETH feeds.
/// @dev Values one stETH at the lower of its protocol accounting value (1 ETH) and market value, then
///      multiplies by stETH-per-wstETH. Both feeds must be fresh and internally consistent.
contract WstEthUsdOracle is IPriceOracle {
    error ZeroAddress();
    error InvalidConfiguration();
    error UnsupportedFeedDecimals();
    error InvalidPrice();
    error StalePrice();
    error InvalidRound();

    uint256 public constant WAD = 1e18;

    IWstETH public immutable wstETH;
    IAggregatorV3 public immutable ethUsdFeed;
    IAggregatorV3 public immutable stEthEthFeed;
    uint256 public immutable maxStaleness;
    uint8 public immutable ethUsdFeedDecimals;
    uint8 public immutable stEthEthFeedDecimals;

    constructor(IWstETH wstETH_, IAggregatorV3 ethUsdFeed_, IAggregatorV3 stEthEthFeed_, uint256 maxStaleness_) {
        if (
            address(wstETH_) == address(0) || address(ethUsdFeed_) == address(0) || address(stEthEthFeed_) == address(0)
        ) revert ZeroAddress();
        if (maxStaleness_ == 0) revert InvalidConfiguration();

        uint8 ethUsdDecimals = ethUsdFeed_.decimals();
        uint8 stEthEthDecimals = stEthEthFeed_.decimals();
        if (ethUsdDecimals > 18 || stEthEthDecimals > 18) revert UnsupportedFeedDecimals();

        wstETH = wstETH_;
        ethUsdFeed = ethUsdFeed_;
        stEthEthFeed = stEthEthFeed_;
        maxStaleness = maxStaleness_;
        ethUsdFeedDecimals = ethUsdDecimals;
        stEthEthFeedDecimals = stEthEthDecimals;
    }

    function price() external view returns (uint256 wstEthUsd) {
        uint256 ethUsd = _readFeed(ethUsdFeed, ethUsdFeedDecimals);
        uint256 stEthEth = _readFeed(stEthEthFeed, stEthEthFeedDecimals);
        uint256 stEthPerWstEth = wstETH.stEthPerToken();
        if (stEthPerWstEth == 0) revert InvalidPrice();

        uint256 effectiveStEthEth = Math.min(WAD, stEthEth);
        uint256 wstEthEth = Math.mulDiv(stEthPerWstEth, effectiveStEthEth, WAD);
        wstEthUsd = Math.mulDiv(ethUsd, wstEthEth, WAD);
        if (wstEthUsd == 0) revert InvalidPrice();
    }

    function _readFeed(IAggregatorV3 feed, uint8 decimals_) internal view returns (uint256 value) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        // Feed freshness necessarily uses the chain timestamp; small validator drift cannot bypass maxStaleness.
        // forge-lint: disable-next-line(block-timestamp)
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert InvalidPrice();
        if (answeredInRound < roundId) revert InvalidRound();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();

        value = Math.mulDiv(SafeCast.toUint256(answer), 10 ** (18 - decimals_), 1);
    }
}
