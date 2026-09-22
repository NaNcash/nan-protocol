// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IReserveOracle} from "./interfaces/IReserveOracle.sol";

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

/// @notice Immutable wstETH/USD router with a direct Chainlink stETH/USD primary and an independent fallback.
/// @dev Normal operations require the primary. Only NaN redemption can use the fallback, with an upward
///      price premium so each redeemed dollar removes less collateral. The fallback must quote wstETH/USD.
contract WstEthUsdOracle is IReserveOracle {
    error ZeroAddress();
    error InvalidConfiguration();
    error UnsupportedFeedDecimals();
    error InvalidPrice();
    error StalePrice();
    error InvalidRound();
    error FallbackUnavailable();

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    IWstETH public immutable wstETH;
    IAggregatorV3 public immutable stEthUsdFeed;
    IPriceOracle public immutable fallbackOracle;
    uint256 public immutable maxStaleness;
    uint256 public immutable fallbackPremiumBps;
    uint8 public immutable stEthUsdFeedDecimals;

    constructor(
        IWstETH wstETH_,
        IAggregatorV3 stEthUsdFeed_,
        IPriceOracle fallbackOracle_,
        uint256 maxStaleness_,
        uint256 fallbackPremiumBps_
    ) {
        if (
            address(wstETH_) == address(0) || address(stEthUsdFeed_) == address(0)
                || address(fallbackOracle_) == address(0)
        ) revert ZeroAddress();
        if (maxStaleness_ == 0 || fallbackPremiumBps_ >= BPS) revert InvalidConfiguration();
        if (address(fallbackOracle_).code.length == 0) revert FallbackUnavailable();

        uint8 feedDecimals = stEthUsdFeed_.decimals();
        if (feedDecimals > 18) revert UnsupportedFeedDecimals();
        try fallbackOracle_.price() returns (uint256 fallbackPrice) {
            if (fallbackPrice == 0) revert FallbackUnavailable();
        } catch {
            revert FallbackUnavailable();
        }

        wstETH = wstETH_;
        stEthUsdFeed = stEthUsdFeed_;
        fallbackOracle = fallbackOracle_;
        maxStaleness = maxStaleness_;
        fallbackPremiumBps = fallbackPremiumBps_;
        stEthUsdFeedDecimals = feedDecimals;
    }

    /// @notice Primary price for minting, funding, defunding, recapitalization, and ordinary reserve views.
    function price() external view returns (uint256 wstEthUsd) {
        uint256 stEthUsd = _readFeed(stEthUsdFeed, stEthUsdFeedDecimals);
        uint256 stEthPerWstEth = wstETH.stEthPerToken();
        if (stEthPerWstEth == 0) revert InvalidPrice();

        wstEthUsd = Math.mulDiv(stEthUsd, stEthPerWstEth, WAD);
        if (wstEthUsd == 0) revert InvalidPrice();
    }

    /// @notice Primary price when valid; otherwise a premium-adjusted independent fallback for redemption.
    function redemptionPrice() external view returns (uint256 collateralPrice, bool fallbackUsed) {
        try this.price() returns (uint256 primaryPrice) {
            return (primaryPrice, false);
        } catch {
            try fallbackOracle.price() returns (uint256 fallbackPrice) {
                if (fallbackPrice == 0) revert FallbackUnavailable();
                collateralPrice = Math.mulDiv(fallbackPrice, BPS + fallbackPremiumBps, BPS, Math.Rounding.Ceil);
                return (collateralPrice, true);
            } catch {
                revert FallbackUnavailable();
            }
        }
    }

    function _readFeed(IAggregatorV3 feed, uint8 decimals_) internal view returns (uint256 value) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        // Feed freshness necessarily uses the chain timestamp; small validator drift cannot bypass maxStaleness.
        // forge-lint: disable-next-line(block-timestamp)
        if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp) revert InvalidPrice();
        if (roundId == 0 || answeredInRound < roundId) revert InvalidRound();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();

        value = Math.mulDiv(SafeCast.toUint256(answer), 10 ** (18 - decimals_), 1);
    }
}
