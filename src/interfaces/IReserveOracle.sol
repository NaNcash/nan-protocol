// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

interface IReserveOracle is IPriceOracle {
    /// @notice USD value of one collateral token for NaN redemption, scaled to 1e18.
    /// @return collateralPrice The quote used to convert USD claims into collateral.
    /// @return fallbackUsed Whether the independent fallback supplied the quote.
    function redemptionPrice() external view returns (uint256 collateralPrice, bool fallbackUsed);
}
