// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "./ERC20.sol";

contract NaNToken is ERC20 {
    error OnlyReserve();

    address public immutable reserve;

    constructor(address reserve_) ERC20("NaN", "NaN") {
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
