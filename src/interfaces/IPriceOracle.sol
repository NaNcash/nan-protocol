// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IPriceOracle {
    /// @notice USD value of one whole collateral token, scaled to 1e18.
    function price() external view returns (uint256);
}
