// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @notice Prevents playground assets from being deployed on a network with real funds.
abstract contract SepoliaOnly {
    error WrongChain();

    constructor() {
        if (block.chainid != 11155111) revert WrongChain();
    }
}
