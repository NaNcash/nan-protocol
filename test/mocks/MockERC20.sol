// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC20Decimals is MockERC20 {
    uint8 private immutable _mockDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_) {
        _mockDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _mockDecimals;
    }
}

contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 private constant FEE_BPS = 100;

    constructor() MockERC20("Fee token", "FEE") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value * FEE_BPS / 10_000;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
