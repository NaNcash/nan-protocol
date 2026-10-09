// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Local-testnet-only independent wstETH/USD fallback simulator.
/// @dev Set to zero to simulate fallback failure. No TWAP protection is provided.
contract LocalFallbackOracle is IPriceOracle {
    uint256 public priceValue = 3_000 ether;

    event PriceUpdated(uint256 price);

    function setPrice(uint256 newPrice) external {
        priceValue = newPrice;
        emit PriceUpdated(newPrice);
    }

    function price() external view returns (uint256) {
        return priceValue;
    }
}
