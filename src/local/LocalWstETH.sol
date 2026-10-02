// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Local-testnet-only wstETH simulator. Not a wrapper for real stETH.
/// @dev Anyone can mint or alter the rate; NEVER deploy this as production collateral.
contract LocalWstETH is ERC20 {
    uint256 public constant MAX_FAUCET_AMOUNT = 1_000 ether;

    error InvalidRate();
    error InvalidFaucetAmount();

    uint256 public stEthPerToken = 1 ether;

    event StEthPerTokenUpdated(uint256 previousRate, uint256 newRate);

    constructor() ERC20("Local Wrapped stETH", "lwstETH") {}

    function faucet(uint256 amount) external {
        if (amount == 0 || amount > MAX_FAUCET_AMOUNT) revert InvalidFaucetAmount();
        _mint(msg.sender, amount);
    }

    function setStEthPerToken(uint256 newRate) external {
        if (newRate == 0) revert InvalidRate();
        uint256 previousRate = stEthPerToken;
        stEthPerToken = newRate;
        emit StEthPerTokenUpdated(previousRate, newRate);
    }
}
