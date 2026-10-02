// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Local-testnet-only Chainlink-compatible stETH/USD feed simulator.
/// @dev A healthy mock round follows Anvil time so time-travelled withdrawals stay usable.
///      Toggle stale/unavailable to exercise the actual router's failure paths.
contract LocalStEthUsdFeed {
    error FeedUnavailable();

    uint8 public constant decimals = 8;
    int256 public answer = 3_000e8;
    uint80 public roundId = 1;
    bool public unavailable;
    bool public stale;

    event AnswerUpdated(int256 answer, uint80 roundId);
    event FeedStatusUpdated(bool unavailable, bool stale);

    function setAnswer(int256 newAnswer) external {
        answer = newAnswer;
        ++roundId;
        emit AnswerUpdated(newAnswer, roundId);
    }

    function setUnavailable(bool value) external {
        unavailable = value;
        emit FeedStatusUpdated(unavailable, stale);
    }

    function setStale(bool value) external {
        stale = value;
        emit FeedStatusUpdated(unavailable, stale);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (unavailable) revert FeedUnavailable();
        uint256 updatedAt = stale && block.timestamp > 2 days ? block.timestamp - 2 days : block.timestamp;
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
