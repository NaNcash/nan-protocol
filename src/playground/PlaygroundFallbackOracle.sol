// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {SepoliaOnly} from "./SepoliaOnly.sol";

/// @notice Owner-controlled diagnostic quote, never used for reserve payouts.
contract PlaygroundFallbackOracle is IPriceOracle, Ownable2Step, SepoliaOnly {
    uint256 public priceValue = 3_000 ether;

    event PriceUpdated(uint256 price);

    constructor(address controller) Ownable(controller) {}

    function setPrice(uint256 newPrice) external onlyOwner {
        priceValue = newPrice;
        emit PriceUpdated(newPrice);
    }

    function price() external view returns (uint256) {
        return priceValue;
    }
}
