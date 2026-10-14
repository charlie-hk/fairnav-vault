// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairNAVVault} from "../src/FairNAVVault.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

/// From an AI-assisted code review: after a near-total loss, can the share-to-asset
/// formula (with its virtual offset) promise more than the pool really holds, so that
/// the last withdrawals revert? Every check below uses the real WETH balance of the
/// pool, never the contract's own conversion functions.
contract NearTotalLossTest is Test {
    FairNAVVault pool;
    MockWETH weth;
    address owner = makeAddr("owner");

    function setUp() public {
        weth = new MockWETH();
        pool = new FairNAVVault(IERC20(address(weth)), owner);
    }

    function _user(uint256 i) internal pure returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(0x20000 + i));
    }

    function _deposit(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(pool), amount);
        pool.deposit(amount, who);
        vm.stopPrank();
    }

    /// Exit `who` completely in as many transactions as the 5 WETH limit needs.
    /// Returns the WETH actually received. Reverts propagate and fail the test.
    function _exitFully(address who) internal returns (uint256 received) {
        uint256 before = weth.balanceOf(who);
        for (uint256 i; i < 50 && pool.balanceOf(who) > 0; i++) {
            uint256 s = pool.maxRedeem(who);
            vm.prank(who);
            pool.redeem(s, who, who);
        }
        assertEq(pool.balanceOf(who), 0, "holder could not exit fully");
        received = weth.balanceOf(who) - before;
    }

    function test_PoolLeftWithOneWei_SingleHolderExits() public {
        _deposit(_user(1), 5 ether);
        vm.prank(owner);
        pool.simulateLoss(5 ether - 1); // 1 wei left
        assertEq(weth.balanceOf(address(pool)), 1);

        uint256 got = _exitFully(_user(1));
        assertLe(got, 1, "paid more than the real balance");
        assertEq(weth.balanceOf(address(pool)), 1 - got);
    }

    function test_PoolLeftWithOneWei_ManyHoldersAllExit() public {
        for (uint256 i; i < 10; i++) _deposit(_user(i), 5 ether - i);
        uint256 bal = weth.balanceOf(address(pool));
        vm.prank(owner);
        pool.simulateLoss(bal - 1); // 1 wei left for 10 holders
        uint256 paid;
        for (uint256 i; i < 10; i++) paid += _exitFully(_user(i));
        assertLe(paid, 1);
        assertEq(pool.totalSupply(), 0, "every share was burned");
    }

    function test_PoolLeftWithZero_HoldersCanStillBurnShares() public {
        _deposit(_user(1), 3 ether);
        _deposit(_user(2), 2 ether);
        vm.prank(owner);
        pool.simulateLoss(5 ether); // nothing left
        assertEq(_exitFully(_user(1)), 0);
        assertEq(_exitFully(_user(2)), 0);
        assertEq(pool.totalSupply(), 0);
    }

    /// Fuzz: any deposits, a loss that leaves 0..1000 wei, everyone exits in random order.
    /// Independent checks: no exit reverts, the sum paid never exceeds the real balance
    /// that was left, and each payout is at most the plain pro-rata amount of the real
    /// balance at that moment plus 1 wei of rounding.
    function testFuzz_NearTotalLoss_EveryoneExits(uint256 seed, uint256 left, uint8 n) public {
        n = uint8(bound(n, 1, 12));
        left = bound(left, 0, 1000);
        for (uint256 i; i < n; i++) {
            _deposit(_user(i), bound(uint256(keccak256(abi.encode(seed, i))), 1, 5 ether));
        }
        uint256 bal = weth.balanceOf(address(pool));
        if (left > bal) left = bal;
        if (bal - left > 0) {
            vm.prank(owner);
            pool.simulateLoss(bal - left);
        }

        uint256 paid;
        for (uint256 k; k < n; k++) {
            address u = _user((seed % n + k) % n);
            uint256 realBal = weth.balanceOf(address(pool));
            uint256 supply = pool.totalSupply();
            uint256 shares = pool.balanceOf(u);
            uint256 got = _exitFully(u);
            // plain pro-rata of the REAL balance, computed here, not by the contract
            assertLe(got, shares * realBal / supply + 1, "payout above pro-rata of real balance");
            paid += got;
        }
        assertLe(paid, left, "paid out more than the pool really held");
        assertEq(pool.totalSupply(), 0);
    }
}
