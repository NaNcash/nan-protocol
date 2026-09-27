// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice The junior residual claim on the NaN reserve.
/// @dev One permanent token per reserve. Recovery funding dilutes existing shares without retiring them.
contract INFToken is ERC20, ERC20Permit {
    error OnlyReserve();
    error ZeroAddress();

    address public immutable reserve;

    constructor(address reserve_) ERC20("NaN Junior", "INF") ERC20Permit("NaN Junior") {
        if (reserve_ == address(0)) revert ZeroAddress();
        reserve = reserve_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != reserve) revert OnlyReserve();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != reserve) revert OnlyReserve();
        _burn(from, amount);
    }
}
