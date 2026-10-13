// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

interface IReserveOracle is IPriceOracle {
    /// @notice Legacy router quote, scaled to 1e18. The reserve uses price() for payouts.
    /// @return collateralPrice The router quote, which may be unsafe for reserve payouts during outages.
    /// @return fallbackUsed Whether the independent fallback supplied the quote.
    function redemptionPrice() external view returns (uint256 collateralPrice, bool fallbackUsed);
}
