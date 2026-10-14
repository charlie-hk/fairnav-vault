// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FairNAVVault} from "../src/FairNAVVault.sol";
import {MockWETH} from "./mocks/MockWETH.sol";

contract FairNAVVaultTest is Test {
    FairNAVVault pool;
    MockWETH weth;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public {
        weth = new MockWETH();
        pool = new FairNAVVault(IERC20(address(weth)), owner);
        weth.mint(owner, 1_000 ether);
        vm.prank(owner);
        weth.approve(address(pool), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers

    function _fund(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.prank(who);
        weth.approve(address(pool), type(uint256).max);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        _fund(who, amount);
        vm.prank(who);
        shares = pool.deposit(amount, who);
    }

    function _user(uint256 i) internal pure returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(0x10000 + i));
    }

    // ------------------------------------------------------------ basics

    function test_DepositMintsSharesWithOffset() public {
        uint256 shares = _deposit(alice, 1 ether);
        assertEq(shares, 1 ether * 1e6, "first deposit mints assets * 10^6 shares");
        assertEq(pool.totalAssets(), 1 ether);
        assertEq(pool.netDeposited(alice), 1 ether);
    }

    function test_WithdrawReturnsPrincipalWhenNoGainOrLoss() public {
        _deposit(alice, 3 ether);
        vm.prank(alice);
        pool.withdraw(3 ether, alice, alice);
        assertEq(weth.balanceOf(alice), 3 ether);
        assertEq(pool.balanceOf(alice), 0);
        assertEq(pool.netDeposited(alice), 0);
    }

    // ------------------------------------------------------------ R2 wallet cap

    function test_WalletCap_ExactlyFiveAllowed() public {
        _deposit(alice, 5 ether);
        assertEq(pool.maxDeposit(alice), 0);
    }

    function test_WalletCap_OneWeiOverReverts() public {
        _fund(alice, 5 ether + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 5 ether + 1, 5 ether)
        );
        pool.deposit(5 ether + 1, alice);
    }

    function test_WalletCap_AppliesAcrossDeposits() public {
        _deposit(alice, 3 ether);
        _fund(alice, 3 ether);
        vm.prank(alice);
        vm.expectRevert();
        pool.deposit(3 ether, alice);
        vm.prank(alice);
        pool.deposit(2 ether, alice);
        assertEq(pool.netDeposited(alice), 5 ether);
    }

    function test_DepositForAnotherReceiverReverts() public {
        // R9: blocks griefing where bob fills alice's wallet cap with a 1 wei deposit
        _fund(bob, 1);
        vm.prank(bob);
        vm.expectRevert(FairNAVVault.ReceiverMustBeCaller.selector);
        pool.deposit(1, alice);
        assertEq(pool.netDeposited(alice), 0);
    }

    function test_FullExitAfterLossResetsWalletCounter() public {
        _deposit(alice, 5 ether);
        vm.prank(owner);
        pool.simulateLoss(4.9 ether); // alice's 5 WETH is now worth 0.1
        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(shares, alice, alice);
        assertEq(pool.netDeposited(alice), 0, "fully exited wallet starts fresh");
    }

    function test_WithdrawOnBehalfToOtherReceiver() public {
        _deposit(alice, 4 ether);
        vm.prank(alice);
        pool.approve(bob, type(uint256).max);
        vm.prank(bob);
        pool.withdraw(1 ether, bob, alice); // bob spends alice's allowance, sends WETH to himself
        assertEq(weth.balanceOf(bob), 1 ether);
        assertEq(pool.netDeposited(alice), 3 ether, "counter follows the share owner");
    }

    function test_OwnershipTransferIsTwoStep() public {
        // a mistyped address can never become owner: the new owner must accept
        address typo = makeAddr("typo");
        vm.prank(owner);
        pool.transferOwnership(typo);
        assertEq(pool.owner(), owner, "owner unchanged until accepted");
        assertEq(pool.pendingOwner(), typo);

        vm.prank(owner);
        pool.transferOwnership(bob); // the mistake can be corrected
        vm.prank(typo);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, typo));
        pool.acceptOwnership();

        vm.prank(bob);
        pool.acceptOwnership();
        assertEq(pool.owner(), bob);
    }

    function test_RenounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(FairNAVVault.RenounceDisabled.selector);
        pool.renounceOwnership();
        assertEq(pool.owner(), owner);
    }

    /// Known limitation, documented in the README: losses are discrete events, so a holder
    /// who exits before a loss transaction lands keeps the old price. The fair-share rule
    /// holds at the moment of each withdrawal, not across the loss event.
    function test_KnownLimitation_ExitBeforeLossAvoidsIt() public {
        _deposit(alice, 5 ether);
        _deposit(bob, 5 ether);
        uint256 shares = pool.balanceOf(bob);
        vm.prank(bob);
        pool.redeem(shares, bob, bob); // bob exits just before the loss
        vm.prank(owner);
        pool.simulateLoss(5 ether);
        assertEq(weth.balanceOf(bob), 5 ether);
        assertLe(pool.fairShareOf(alice), 1, "alice carries the whole loss");
    }

    function test_WalletCap_FreedAfterWithdraw() public {
        _deposit(alice, 5 ether);
        vm.prank(alice);
        pool.withdraw(2 ether, alice, alice);
        assertEq(pool.maxDeposit(alice), 2 ether);
    }

    function test_MintRespectsCaps() public {
        _fund(alice, 10 ether);
        uint256 maxShares = pool.maxMint(alice);
        vm.prank(alice);
        pool.mint(maxShares, alice);
        assertLe(pool.netDeposited(alice), 5 ether);
        vm.prank(alice);
        vm.expectRevert();
        pool.mint(1e6, alice);
    }

    // ------------------------------------------------------------ R1 total cap

    function test_TotalCap_TwentyFullWalletsFillThePool() public {
        for (uint256 i; i < 20; i++) _deposit(_user(i), 5 ether);
        assertEq(pool.totalAssets(), 100 ether);
        assertEq(pool.maxDeposit(_user(20)), 0);

        _fund(_user(20), 1);
        vm.prank(_user(20));
        vm.expectRevert();
        pool.deposit(1, _user(20));
    }

    function test_TotalCap_PartialRoomIsTheLimit() public {
        for (uint256 i; i < 19; i++) _deposit(_user(i), 5 ether);
        _deposit(_user(19), 3 ether);
        assertEq(pool.maxDeposit(_user(20)), 2 ether);
    }

    function test_TotalCap_GainsDoNotCloseDeposits() public {
        // R1 is measured on principal, so a gain that lifts the balance above 100 WETH
        // does not lock out new depositors
        for (uint256 i; i < 19; i++) _deposit(_user(i), 5 ether);
        vm.prank(owner);
        pool.simulateGain(10 ether); // 105 WETH in the pool, 95 WETH principal
        assertEq(pool.totalPrincipal(), 95 ether);
        assertEq(pool.maxDeposit(alice), 5 ether);
        _deposit(alice, 5 ether);
        assertEq(pool.maxDeposit(bob), 0, "principal is now at the 100 WETH cap");
    }

    // ------------------------------------------------------------ R3 withdraw limit

    function test_WithdrawLimit_FiveAllowed_OverReverts() public {
        _deposit(alice, 5 ether);
        _deposit(bob, 5 ether);
        vm.prank(owner);
        pool.simulateGain(10 ether); // alice now owns ~10 WETH

        assertEq(pool.maxWithdraw(alice), 5 ether);
        vm.prank(alice);
        vm.expectRevert();
        pool.withdraw(5 ether + 1, alice, alice);

        vm.prank(alice);
        pool.withdraw(5 ether, alice, alice);
        assertEq(weth.balanceOf(alice), 5 ether);
    }

    function test_WithdrawLimit_RedeemAllAfterGainReverts_SplitWorks() public {
        _deposit(alice, 5 ether);
        vm.prank(owner);
        pool.simulateGain(5 ether); // alice owns ~10 WETH

        uint256 allShares = pool.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        pool.redeem(allShares, alice, alice);

        // exit in two transactions
        uint256 maxR = pool.maxRedeem(alice);
        vm.prank(alice);
        uint256 got1 = pool.redeem(maxR, alice, alice);
        assertLe(got1, 5 ether);
        uint256 rest = pool.balanceOf(alice);
        vm.prank(alice);
        uint256 got2 = pool.redeem(rest, alice, alice);
        assertApproxEqAbs(got1 + got2, 10 ether, 2, "full exit returns everything minus rounding");
    }

    function test_MaxRedeemNeverPaysMoreThanLimit() public {
        _deposit(alice, 5 ether);
        vm.prank(owner);
        pool.simulateGain(7 ether);
        uint256 maxR = pool.maxRedeem(alice);
        assertLe(pool.previewRedeem(maxR), 5 ether);
    }

    // ------------------------------------------------------------ R4 pause

    function test_Pause_BlocksDepositAndMint() public {
        vm.prank(owner);
        pool.pause();
        assertEq(pool.maxDeposit(alice), 0);
        assertEq(pool.maxMint(alice), 0);

        _fund(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert();
        pool.deposit(1 ether, alice);
        vm.expectRevert();
        pool.mint(1e6, alice);
        vm.stopPrank();
    }

    function test_Pause_WithdrawAndRedeemStillWork() public {
        _deposit(alice, 4 ether);
        vm.prank(owner);
        pool.pause();

        assertEq(pool.maxWithdraw(alice), 4 ether);
        vm.prank(alice);
        pool.withdraw(1 ether, alice, alice);

        uint256 rest = pool.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(rest, alice, alice);
        assertEq(weth.balanceOf(alice), 4 ether);
    }

    function test_Unpause_RestoresDeposits() public {
        vm.startPrank(owner);
        pool.pause();
        pool.unpause();
        vm.stopPrank();
        _deposit(alice, 1 ether);
    }

    function test_OnlyOwnerCanPause() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.pause();
    }

    // ------------------------------------------------------------ R6 transfers

    function test_SharesAreNonTransferable() public {
        _deposit(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(FairNAVVault.SharesNonTransferable.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        pool.transfer(bob, 1);

        vm.prank(alice);
        pool.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(FairNAVVault.SharesNonTransferable.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        pool.transferFrom(alice, bob, 1);
    }

    // ------------------------------------------------------------ R7 simulation + R5 fair share

    function test_LossIsSharedProRata() public {
        _deposit(alice, 4 ether);
        _deposit(bob, 1 ether);
        vm.prank(owner);
        pool.simulateLoss(2.5 ether); // pool loses half

        assertApproxEqAbs(pool.fairShareOf(alice), 2 ether, 1);
        assertApproxEqAbs(pool.fairShareOf(bob), 0.5 ether, 1);

        // bob exits first; alice must still be able to take her full half-sized share
        uint256 bobShares = pool.balanceOf(bob);
        vm.prank(bob);
        uint256 bobGot = pool.redeem(bobShares, bob, bob);
        assertLe(bobGot, 0.5 ether);

        uint256 aliceShares = pool.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceGot = pool.redeem(aliceShares, alice, alice);
        assertApproxEqAbs(aliceGot, 2 ether, 1);
        assertLe(bobGot + aliceGot, 2.5 ether, "never pays out more than the pool holds");
    }

    function test_LossGoesToBurnAddressNotOwner() public {
        _deposit(alice, 5 ether);
        uint256 ownerBefore = weth.balanceOf(owner);
        vm.prank(owner);
        pool.simulateLoss(1 ether);
        assertEq(weth.balanceOf(owner), ownerBefore, "owner gains nothing from a loss");
        assertEq(weth.balanceOf(pool.LOSS_SINK()), 1 ether);
    }

    function test_LossCannotExceedAssets() public {
        _deposit(alice, 1 ether);
        vm.prank(owner);
        vm.expectRevert(FairNAVVault.LossExceedsAssets.selector);
        pool.simulateLoss(1 ether + 1);
    }

    function test_OnlyOwnerCanSimulate() public {
        _deposit(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.simulateLoss(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.simulateGain(1);
        vm.stopPrank();
    }

    function test_TotalLoss_ClosesDepositsButNotWithdrawals() public {
        _deposit(alice, 5 ether);
        vm.prank(owner);
        pool.simulateLoss(5 ether); // pool wiped out, alice still holds shares
        assertFalse(pool.depositsOpen());
        assertEq(pool.maxDeposit(bob), 0);

        _fund(bob, 2 ether);
        vm.prank(bob);
        vm.expectRevert();
        pool.deposit(2 ether, bob); // new money cannot enter a failed pool

        uint256 shares = pool.balanceOf(alice);
        vm.prank(alice);
        pool.redeem(shares, alice, alice); // exit still works (pays 0)
        assertEq(pool.balanceOf(alice), 0);
    }

    function test_PriceFloor_DepositsOpenAt99PercentLossClosedBelow() public {
        _deposit(alice, 5 ether);
        vm.prank(owner);
        pool.simulateLoss(4.95 ether); // price = 1% of launch -> still open
        assertTrue(pool.depositsOpen());
        vm.prank(owner);
        pool.simulateLoss(0.01 ether); // below 1% -> closed
        assertFalse(pool.depositsOpen());

        vm.prank(owner);
        pool.simulateGain(1 ether); // recovery above the floor reopens deposits
        assertTrue(pool.depositsOpen());
    }

    function test_DepositAfterLossDoesNotTakeFromOldHolders() public {
        _deposit(alice, 5 ether);
        vm.prank(owner);
        pool.simulateLoss(4 ether); // alice now owns 1 WETH
        _deposit(bob, 2 ether);
        assertApproxEqAbs(pool.fairShareOf(alice), 1 ether, 1);
        assertApproxEqAbs(pool.fairShareOf(bob), 2 ether, 1);
    }

    // ------------------------------------------------------------ inflation attack

    function test_InflationAttackIsUnprofitable() public {
        // attacker: 1 wei deposit, then a large direct donation to inflate the share price
        _deposit(attacker, 1);
        weth.mint(attacker, 10 ether);
        vm.prank(attacker);
        assertTrue(weth.transfer(address(pool), 10 ether));

        // victim deposits the full wallet cap
        uint256 victimShares = _deposit(alice, 5 ether);
        assertGt(victimShares, 0, "victim always receives shares");

        uint256 victimValue = pool.fairShareOf(alice);
        assertGe(victimValue, 5 ether - 5 ether / 1e6, "victim loses at most 1 ppm to rounding");

        uint256 attackerValue = pool.fairShareOf(attacker);
        assertApproxEqAbs(attackerValue, 5 ether, 0.001 ether, "attacker keeps only ~5 of the 10 WETH donated");
    }

    // ------------------------------------------------------------ fuzz

    /// R5: after any deposits and any loss, each redeem pays at most the
    /// pro-rata amount of the current pool (plus at most 1 wei rounding),
    /// and the sum of all payouts never exceeds the pool.
    function testFuzz_FairShareAfterLoss(uint256 a, uint256 b, uint256 c, uint256 lossBps) public {
        a = bound(a, 1, 5 ether);
        b = bound(b, 1, 5 ether);
        c = bound(c, 1, 5 ether);
        lossBps = bound(lossBps, 0, 10_000);

        _deposit(_user(1), a);
        _deposit(_user(2), b);
        _deposit(_user(3), c);

        uint256 loss = pool.totalAssets() * lossBps / 10_000;
        if (loss > 0) {
            vm.prank(owner);
            pool.simulateLoss(loss);
        }

        uint256 poolBefore = pool.totalAssets();
        uint256 paid;
        for (uint256 i = 1; i <= 3; i++) {
            address u = _user(i);
            uint256 shares = pool.balanceOf(u);
            uint256 fair = shares * pool.totalAssets() / pool.totalSupply();
            vm.prank(u);
            uint256 got = pool.redeem(shares, u, u);
            assertLe(got, fair + 1, "payout above pro-rata share");
            paid += got;
        }
        assertLe(paid, poolBefore, "paid out more than the pool held");
    }

    function testFuzz_DepositNeverBreaksCaps(uint256 amount) public {
        amount = bound(amount, 1, 20 ether);
        _fund(alice, amount);
        vm.prank(alice);
        try pool.deposit(amount, alice) {
            assertLe(amount, 5 ether);
        } catch {
            assertGt(amount, 5 ether);
        }
        assertLe(pool.netDeposited(alice), 5 ether);
    }

    function testFuzz_WithdrawNeverAboveLimit(uint256 gain, uint256 amount) public {
        gain = bound(gain, 0, 50 ether);
        _deposit(alice, 5 ether);
        if (gain > 0) {
            vm.prank(owner);
            pool.simulateGain(gain);
        }
        amount = bound(amount, 1, 60 ether);
        uint256 before = weth.balanceOf(alice);
        vm.prank(alice);
        try pool.withdraw(amount, alice, alice) {
            assertLe(weth.balanceOf(alice) - before, 5 ether);
        } catch {
            assertTrue(amount > 5 ether || amount > pool.fairShareOf(alice));
        }
    }

    function testFuzz_InflationDonationNeverStealsFromVictim(uint256 donation, uint256 victimDeposit) public {
        // a direct donation can push the pool to the 100 WETH cap; keep room for the victim
        donation = bound(donation, 1, 95 ether - 1);
        victimDeposit = bound(victimDeposit, 1 ether, 5 ether);
        _deposit(attacker, 1);
        weth.mint(attacker, donation);
        vm.prank(attacker);
        assertTrue(weth.transfer(address(pool), donation));

        _deposit(alice, victimDeposit);
        // victim loses at most ~1 ppm of the donation-inflated price step (bounded rounding)
        uint256 maxLoss = (donation + 1) / 1e6 + 1;
        assertGe(pool.fairShareOf(alice) + maxLoss, victimDeposit);
    }
}
