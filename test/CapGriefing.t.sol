// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairNAVVault} from "../src/FairNAVVault.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// From an AI-assisted code review: if the 100 WETH cap is measured on the real balance,
/// one wallet can deposit 5, donate 95, close deposits for everyone, then withdraw
/// almost everything back. The cap must therefore be measured on deposited principal.
contract CapGriefingTest is Test {
    FairNAVVault pool;
    MockWETH weth;
    address owner = makeAddr("owner");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");

    function setUp() public {
        weth = new MockWETH();
        pool = new FairNAVVault(IERC20(address(weth)), owner);
    }

    function test_DonationCannotCloseDepositsForOthers() public {
        weth.mint(attacker, 100 ether);
        vm.startPrank(attacker);
        weth.approve(address(pool), type(uint256).max);
        pool.deposit(5 ether, attacker);
        assertTrue(weth.transfer(address(pool), 95 ether)); // pool now holds 100 WETH
        vm.stopPrank();

        assertEq(pool.maxDeposit(alice), 5 ether, "alice must still be able to deposit");
        weth.mint(alice, 5 ether);
        vm.startPrank(alice);
        weth.approve(address(pool), 5 ether);
        pool.deposit(5 ether, alice);
        vm.stopPrank();

        // and the attack is not free: the donation is shared with alice
        uint256 got;
        for (uint256 i; i < 30 && pool.balanceOf(attacker) > 0; i++) {
            uint256 s = pool.maxRedeem(attacker);
            vm.prank(attacker);
            got += pool.redeem(s, attacker, attacker);
        }
        assertLt(got, 100 ether, "attacker cannot recover the whole donation");
    }
}
