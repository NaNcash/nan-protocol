// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

contract MockWstETH {
    uint256 public stEthPerToken;

    constructor(uint256 rate_) {
        stEthPerToken = rate_;
    }

    function setStEthPerToken(uint256 rate_) external {
        stEthPerToken = rate_;
    }
}

contract MockAggregator {
    uint8 public immutable decimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        setRoundData(1, answer_, updatedAt_, 1);
    }

    function setRoundData(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) public {
        roundId = roundId_;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
