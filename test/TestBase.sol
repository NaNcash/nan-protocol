// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert(bytes4) external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error AssertionFailed(string message);

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        if (a != b) revert AssertionFailed(message);
    }

    function assertGt(uint256 a, uint256 b, string memory message) internal pure {
        if (a <= b) revert AssertionFailed(message);
    }

    function assertLt(uint256 a, uint256 b, string memory message) internal pure {
        if (a >= b) revert AssertionFailed(message);
    }

    function assertLe(uint256 a, uint256 b, string memory message) internal pure {
        if (a > b) revert AssertionFailed(message);
    }

    function assertApproxEqAbs(uint256 a, uint256 b, uint256 tolerance, string memory message) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        if (diff > tolerance) revert AssertionFailed(message);
    }
}
