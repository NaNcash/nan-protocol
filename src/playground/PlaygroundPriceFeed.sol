// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SepoliaOnly} from "./SepoliaOnly.sol";

/// @notice Owner-controlled synthetic USD feed for the Sepolia playground.
/// @dev Healthy quotes stay fresh without keeper transactions. This is not market data.
contract PlaygroundPriceFeed is Ownable2Step, SepoliaOnly {
    error FeedUnavailable();

    uint8 public constant decimals = 8;
    int256 public answer = 3_000e8;
    uint80 public roundId = 1;
    bool public unavailable;
    bool public stale;

    event AnswerUpdated(int256 answer, uint80 roundId);
    event FeedStatusUpdated(bool unavailable, bool stale);

    constructor(address controller) Ownable(controller) {}

    // Zero/negative answers are allowed for deliberate oracle-failure scenarios.
    function setAnswer(int256 newAnswer) external onlyOwner {
        answer = newAnswer;
        ++roundId;
        emit AnswerUpdated(newAnswer, roundId);
    }

    function setUnavailable(bool value) external onlyOwner {
        unavailable = value;
        emit FeedStatusUpdated(unavailable, stale);
    }

    function setStale(bool value) external onlyOwner {
        stale = value;
        emit FeedStatusUpdated(unavailable, stale);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (unavailable) revert FeedUnavailable();
        // Synthetic freshness deliberately follows chain time; this is not a market-data timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 updatedAt = stale ? (block.timestamp > 2 days ? block.timestamp - 2 days : 0) : block.timestamp;
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
