// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NaNToken} from "../src/NaNToken.sol";
import {INFToken} from "../src/INFToken.sol";

contract TokenTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function testNanSupportsErc2612Permit() public {
        NaNToken token = new NaNToken(address(this));
        (address owner, uint256 ownerKey) = makeAddrAndKey("owner");
        address spender = makeAddr("spender");
        uint256 value = 123e18;
        uint256 deadline = block.timestamp + 1 days;

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
    }

    function testTokenConstructorsRejectZeroReserve() public {
        vm.expectRevert(NaNToken.ZeroAddress.selector);
        new NaNToken(address(0));
        vm.expectRevert(INFToken.ZeroAddress.selector);
        new INFToken(address(0));
    }
}
