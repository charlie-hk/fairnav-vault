// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairNAVVault} from "../../src/FairNAVVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {Handler} from "./Handler.sol";

contract FairNAVVaultInvariantTest is Test {
    FairNAVVault pool;
    MockWETH weth;
    Handler handler;
    address owner = makeAddr("owner");

    function setUp() public {
        weth = new MockWETH();
        pool = new FairNAVVault(IERC20(address(weth)), owner);
        handler = new Handler(pool, weth, owner);
        vm.prank(owner);
        weth.approve(address(pool), type(uint256).max);
        targetContract(address(handler));
    }

    /// R5 core: no single withdrawal or redeem ever paid more than the
    /// caller's pro-rata share of the pool at that moment (1 wei rounding allowed).
    function invariant_NoPayoutAboveFairShare() public view {
        assertFalse(handler.ghost_payoutAboveFairShare());
    }

    /// Independent ledger: the pool's real WETH balance equals everything the handler
    /// saw going in minus everything it saw going out. Nothing leaks or appears.
    function invariant_RealBalanceMatchesLedger() public view {
        assertEq(weth.balanceOf(address(pool)), handler.ghost_wethIn() - handler.ghost_wethOut());
    }

    /// R5 solvency, checked by doing it, not by the contract's formula: from the current
    /// state, every holder exits completely (in 5 WETH steps). No exit may revert, the total
    /// paid may not exceed the pool's real WETH balance, and every share must be burned.
    /// The state is restored afterwards so the run continues unchanged.
    function invariant_EveryoneCanExitFully() public {
        uint256 snap = vm.snapshotState();
        uint256 realBal = weth.balanceOf(address(pool));
        uint256 paid;
        for (uint256 i; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            uint256 before = weth.balanceOf(a);
            for (uint256 k; k < 60 && pool.balanceOf(a) > 0; k++) {
                uint256 s = pool.maxRedeem(a);
                vm.prank(a);
                pool.redeem(s, a, a);
            }
            assertEq(pool.balanceOf(a), 0, "holder could not exit fully");
            paid += weth.balanceOf(a) - before;
        }
        assertLe(paid, realBal, "paid more than the pool really held");
        assertEq(pool.totalSupply(), 0);
        vm.revertToState(snap);
    }

    /// Users acting on the pool (deposit / withdraw / redeem) can never
    /// lower the share price for others. Only a simulated loss can.
    function invariant_UsersCannotDiluteOthers() public view {
        assertFalse(handler.ghost_priceDroppedOnUserAction());
    }

    /// R1: no deposit was ever accepted that took the pool above 100 WETH.
    function invariant_TotalCapAtDeposit() public view {
        assertFalse(handler.ghost_depositBrokeTotalCap());
    }

    /// Code review finding: every deposit or mint that the written rules allow succeeded,
    /// and every one they forbid reverted. Checked against the handler's own model.
    function invariant_DepositsFollowTheRules() public view {
        assertFalse(handler.ghost_validDepositReverted(), "an allowed deposit reverted");
        assertFalse(handler.ghost_invalidDepositSucceeded(), "a forbidden deposit succeeded");
    }

    /// R1/R2 bookkeeping matches an independent model, and total principal stays within 100 WETH.
    function invariant_PrincipalMatchesModel() public view {
        assertFalse(handler.ghost_principalMismatch());
        assertEq(pool.totalPrincipal(), handler.modelTotalPrincipal());
        assertLe(pool.totalPrincipal(), pool.TOTAL_CAP());
    }

    /// R2: no wallet ever holds more than 5 WETH of net principal.
    function invariant_WalletCap() public view {
        for (uint256 i; i < handler.actorCount(); i++) {
            assertLe(pool.netDeposited(handler.actors(i)), pool.WALLET_CAP());
        }
    }

    /// R3: no single withdrawal or redeem ever paid more than 5 WETH.
    function invariant_PerTxWithdrawLimit() public view {
        assertLe(handler.ghost_maxSinglePayout(), pool.MAX_WITHDRAW_PER_TX());
    }

    /// R4: deposits never succeed while paused...
    function invariant_PauseBlocksDeposits() public view {
        assertFalse(handler.ghost_depositSucceededWhilePaused());
    }

    /// ...and a withdrawal within the user's limit never reverts, paused or not.
    function invariant_WithdrawalsAlwaysAvailable() public view {
        assertFalse(handler.ghost_validWithdrawReverted());
    }

    /// Shares never move between wallets, so supply equals the sum of actor balances.
    function invariant_SupplyMatchesHolders() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); i++) {
            sum += pool.balanceOf(handler.actors(i));
        }
        assertEq(sum, pool.totalSupply());
    }

    /// Coverage evidence: shows that paused withdrawals and losses really happened in the run.
    function afterInvariant() public view {
        console.log("withdrawals while paused:", handler.ghost_withdrawalsWhilePaused());
        console.log("deposit attempts while paused:", handler.ghost_depositAttemptsWhilePaused());
        console.log("simulated losses:", handler.ghost_losses());
        console.log("allowed deposits that succeeded:", handler.ghost_validDepositsSucceeded());
    }
}
