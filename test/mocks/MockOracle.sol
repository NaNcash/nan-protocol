// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IReserveOracle} from "../../src/interfaces/IReserveOracle.sol";

contract MockOracle is IReserveOracle {
    uint256 public priceValue;

    constructor(uint256 price_) {
        priceValue = price_;
    }

    function setPrice(uint256 price_) external {
        priceValue = price_;
    }

    function price() external view returns (uint256) {
        return priceValue;
    }

    function redemptionPrice() external view returns (uint256, bool) {
        return (priceValue, false);
    }
}
