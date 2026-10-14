// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SepoliaOnly} from "./SepoliaOnly.sol";

/// @notice Freely mintable Sepolia collateral with no backing or monetary value.
/// @dev Not native ETH and not redeemable for ETH. The rate only simulates yield.
contract PlaygroundETH is ERC20, Ownable2Step, SepoliaOnly {
    uint256 public constant MAX_FAUCET_AMOUNT = 1_000 ether;

    error InvalidRate();
    error InvalidFaucetAmount();

    // Compatibility with the existing wstETH oracle; starts at a 1:1 simulated rate.
    uint256 public stEthPerToken = 1 ether;

    event StEthPerTokenUpdated(uint256 previousRate, uint256 newRate);

    constructor(address controller) ERC20("Playground Ether", "pgETH") Ownable(controller) {}

    function faucet(uint256 amount) external {
        if (amount == 0 || amount > MAX_FAUCET_AMOUNT) revert InvalidFaucetAmount();
        _mint(msg.sender, amount);
    }

    function setStEthPerToken(uint256 newRate) external onlyOwner {
        if (newRate == 0) revert InvalidRate();
        uint256 previousRate = stEthPerToken;
        stEthPerToken = newRate;
        emit StEthPerTokenUpdated(previousRate, newRate);
    }
}
