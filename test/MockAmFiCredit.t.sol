// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDr} from "../src/MockUSDr.sol";
import {MockAmFiCredit} from "../src/MockAmFiCredit.sol";

contract MockAmFiCreditTest is Test {
    MockUSDr usdr;
    MockAmFiCredit amfi;

    address owner = address(this);
    address alice = makeAddr("alice");

    uint256 constant INITIAL_SUPPLY = 500_000 * 1e18;
    uint256 constant INITIAL_NAV = 1_000_000; // $1.00

    function setUp() public {
        usdr = new MockUSDr(1_000_000 * 1e6);
        amfi = new MockAmFiCredit(INITIAL_SUPPLY, INITIAL_NAV, address(usdr));
    }

    function test_Constructor_MintsInitialSupplyToDeployer() public view {
        assertEq(amfi.balanceOf(owner), INITIAL_SUPPLY);
        assertEq(amfi.navPerToken(), INITIAL_NAV);
        assertEq(address(amfi.redemptionAsset()), address(usdr));
    }

    function test_Constructor_RevertsOnZeroNav() public {
        vm.expectRevert("nav must be > 0");
        new MockAmFiCredit(INITIAL_SUPPLY, 0, address(usdr));
    }

    function test_Constructor_RevertsOnZeroRedemptionAsset() public {
        vm.expectRevert("zero redemption asset");
        new MockAmFiCredit(INITIAL_SUPPLY, INITIAL_NAV, address(0));
    }

    function test_Mint_OnlyOwner() public {
        amfi.mint(alice, 1000 * 1e18);
        assertEq(amfi.balanceOf(alice), 1000 * 1e18);

        vm.prank(alice);
        vm.expectRevert();
        amfi.mint(alice, 1);
    }

    function test_SetNav_UpdatesAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit MockAmFiCredit.NavUpdated(INITIAL_NAV, 700_000);
        amfi.setNav(700_000);
        assertEq(amfi.navPerToken(), 700_000);
    }

    function test_SetNav_RevertsOnZero() public {
        vm.expectRevert("nav must be > 0");
        amfi.setNav(0);
    }

    function test_SetNav_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        amfi.setNav(500_000);
    }

    function test_FundRedemptionPool_TransfersInAndEmits() public {
        usdr.approve(address(amfi), 50_000 * 1e6);
        vm.expectEmit(true, true, true, true);
        emit MockAmFiCredit.RedemptionPoolFunded(owner, 50_000 * 1e6);
        amfi.fundRedemptionPool(50_000 * 1e6);
        assertEq(usdr.balanceOf(address(amfi)), 50_000 * 1e6);
    }

    function test_Redeem_BurnsAndPaysOutAtNav() public {
        usdr.approve(address(amfi), 100_000 * 1e6);
        amfi.fundRedemptionPool(100_000 * 1e6);

        amfi.transfer(alice, 10_000 * 1e18);

        vm.prank(alice);
        uint256 paid = amfi.redeem(10_000 * 1e18);

        // NAV is $1.00 -> 10,000 mAMFI redeems for 10,000 mUSDr (6 decimals)
        assertEq(paid, 10_000 * 1e6);
        assertEq(amfi.balanceOf(alice), 0);
        assertEq(usdr.balanceOf(alice), 10_000 * 1e6);
    }

    function test_Redeem_RevertsIfPoolInsufficient() public {
        // Pool is unfunded (0 balance).
        amfi.transfer(alice, 10_000 * 1e18);

        vm.prank(alice);
        vm.expectRevert("redemption pool insufficient");
        amfi.redeem(10_000 * 1e18);
    }

    function test_Redeem_RevertsOnZeroAmount() public {
        vm.expectRevert("zero amount");
        amfi.redeem(0);
    }

    function test_Redeem_RespectsUpdatedNav() public {
        usdr.approve(address(amfi), 100_000 * 1e6);
        amfi.fundRedemptionPool(100_000 * 1e6);
        amfi.setNav(700_000); // $0.70

        amfi.transfer(alice, 10_000 * 1e18);
        vm.prank(alice);
        uint256 paid = amfi.redeem(10_000 * 1e18);

        assertEq(paid, 7_000 * 1e6);
    }
}
