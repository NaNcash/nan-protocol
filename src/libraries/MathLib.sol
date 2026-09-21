// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

library MathLib {
    error DivisionByZero();
    error MulDivOverflow();

    function mulDivDown(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert DivisionByZero();
        if (x != 0 && y > type(uint256).max / x) revert MulDivOverflow();
        return (x * y) / denominator;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
