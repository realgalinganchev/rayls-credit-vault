// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDr} from "../src/MockUSDr.sol";

contract MockUSDrTest is Test {
    MockUSDr usdr;
    address alice = makeAddr("alice");

    function setUp() public {
        usdr = new MockUSDr(1_000_000 * 1e6);
    }

    function test_Constructor_MintsInitialSupply() public view {
        assertEq(usdr.balanceOf(address(this)), 1_000_000 * 1e6);
        assertEq(usdr.totalSupply(), 1_000_000 * 1e6);
    }

    function test_Decimals_IsSix() public view {
        assertEq(usdr.decimals(), 6);
    }

    function test_Mint_OnlyOwner() public {
        usdr.mint(alice, 500 * 1e6);
        assertEq(usdr.balanceOf(alice), 500 * 1e6);

        vm.prank(alice);
        vm.expectRevert();
        usdr.mint(alice, 1);
    }
}
