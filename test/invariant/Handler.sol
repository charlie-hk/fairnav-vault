// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairNAVVault} from "../../src/FairNAVVault.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/// @dev Drives random sequences of user and owner actions against the pool and
///      records "ghost" facts that the invariant test then asserts on.
contract Handler is Test {
    FairNAVVault public pool;
    MockWETH public weth;
    address public owner;
    address[] public actors;

    // ghost state
    bool public ghost_payoutAboveFairShare;
    bool public ghost_depositSucceededWhilePaused;
    bool public ghost_validWithdrawReverted;
    bool public ghost_priceDroppedOnUserAction;
    bool public ghost_depositBrokeTotalCap;
    uint256 public ghost_maxSinglePayout;
    uint256 public ghost_withdrawalsWhilePaused;
    uint256 public ghost_depositAttemptsWhilePaused;
    uint256 public ghost_losses;
    // independent WETH ledger: every unit that entered or left the pool, counted by the handler
    uint256 public ghost_wethIn;
    uint256 public ghost_wethOut;
    // code review finding: a deposit/mint the rules allow must succeed, one they forbid must revert
    bool public ghost_validDepositReverted;
    bool public ghost_invalidDepositSucceeded;
    uint256 public ghost_validDepositsSucceeded;
    // independent model of R1/R2 principal, kept by the handler from the written rules
    mapping(address => uint256) public modelPrincipal;
    uint256 public modelTotalPrincipal;
    bool public ghost_principalMismatch;

    uint256 internal constant V = 1e6; // 10 ** OFFSET

    constructor(FairNAVVault _pool, MockWETH _weth, address _owner) {
        pool = _pool;
        weth = _weth;
        owner = _owner;
        for (uint256 i; i < 6; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            vm.prank(a);
            weth.approve(address(pool), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // --------------------------------------------------------- helpers

    /// the pool's real WETH balance, read from the token, not from the pool
    function _realBal() internal view returns (uint256) {
        return weth.balanceOf(address(pool));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// share price = (A + 1) / (S + V); returns true if price after < price before
    function _priceDropped(uint256 a0, uint256 s0, uint256 a1, uint256 s1) internal pure returns (bool) {
        return (a1 + 1) * (s0 + V) < (a0 + 1) * (s1 + V);
    }

    /// `realBalBefore` is weth.balanceOf(pool) read by the handler before the call,
    /// so the check does not rely on the contract's own conversion functions.
    function _checkPayout(uint256 shares, uint256 got, uint256 realBalBefore, uint256 supplyBefore) internal {
        if (got > ghost_maxSinglePayout) ghost_maxSinglePayout = got;
        ghost_wethOut += got;
        uint256 fair = shares * realBalBefore / supplyBefore;
        if (got > fair + 1) ghost_payoutAboveFairShare = true;
    }

    // --------------------------------------------------------- independent rule model

    /// Room left under R1 and R2 according to the handler's own model.
    function _modelRoom(address a) internal view returns (uint256) {
        uint256 roomTotal = modelTotalPrincipal >= 100 ether ? 0 : 100 ether - modelTotalPrincipal;
        uint256 roomWallet = modelPrincipal[a] >= 5 ether ? 0 : 5 ether - modelPrincipal[a];
        return roomTotal < roomWallet ? roomTotal : roomWallet;
    }

    /// R8 computed here from the real balance: price >= 1% of the launch price.
    function _modelDepositsOpen() internal view returns (bool) {
        return (_realBal() + 1) * V * 100 >= pool.totalSupply() + V;
    }

    /// Should a deposit of `assets` by `a` (for itself) succeed under the written rules?
    function _modelDepositAllowed(address a, uint256 assets) internal view returns (bool) {
        if (pool.paused() || !_modelDepositsOpen()) return false;
        if (assets == 0 || assets > _modelRoom(a)) return false;
        // must mint at least one share: assets * (S + V) / (A + 1) >= 1
        return assets * (pool.totalSupply() + V) >= _realBal() + 1;
    }

    function _modelAfterDeposit(address a, uint256 assets) internal {
        modelPrincipal[a] += assets;
        modelTotalPrincipal += assets;
        _checkPrincipal(a);
    }

    function _modelAfterWithdraw(address o, uint256 paid) internal {
        uint256 p = modelPrincipal[o];
        uint256 reduce = paid >= p ? p : paid;
        if (pool.balanceOf(o) == 0) reduce = p; // full exit resets the wallet
        modelPrincipal[o] = p - reduce;
        modelTotalPrincipal -= reduce;
        _checkPrincipal(o);
    }

    function _checkPrincipal(address a) internal {
        if (pool.netDeposited(a) != modelPrincipal[a] || pool.totalPrincipal() != modelTotalPrincipal) {
            ghost_principalMismatch = true;
        }
    }

    // --------------------------------------------------------- user actions

    function deposit(uint256 actorSeed, uint256 amount) public {
        address a = _actor(actorSeed);
        uint256 room = _modelRoom(a);
        // half the time aim inside the allowed room, otherwise anywhere (including over the caps)
        amount = (actorSeed % 2 == 0 && room > 0) ? bound(amount, 1, room) : bound(amount, 1, 6 ether);
        _depositExact(a, amount);
    }

    function _depositExact(address a, uint256 amount) internal {
        weth.mint(a, amount);
        bool wasPaused = pool.paused();
        bool allowed = _modelDepositAllowed(a, amount);
        uint256 a0 = _realBal();
        uint256 s0 = pool.totalSupply();

        if (wasPaused) ghost_depositAttemptsWhilePaused++;
        uint256 userBefore = weth.balanceOf(a);
        vm.prank(a);
        try pool.deposit(amount, a) {
            ghost_wethIn += userBefore - weth.balanceOf(a);
            if (!allowed) ghost_invalidDepositSucceeded = true;
            else ghost_validDepositsSucceeded++;
            if (wasPaused) ghost_depositSucceededWhilePaused = true;
            if (modelTotalPrincipal + amount > 100 ether) ghost_depositBrokeTotalCap = true;
            _modelAfterDeposit(a, amount);
            if (_priceDropped(a0, s0, _realBal(), pool.totalSupply())) ghost_priceDroppedOnUserAction = true;
        } catch {
            if (allowed) ghost_validDepositReverted = true;
        }
    }

    function withdraw(uint256 actorSeed, uint256 amount) public {
        address a = _actor(actorSeed);
        uint256 maxW = pool.maxWithdraw(a);
        if (maxW == 0) return;
        amount = bound(amount, 1, maxW);
        bool wasPaused = pool.paused();
        uint256 a0 = _realBal();
        uint256 s0 = pool.totalSupply();
        uint256 sharesBefore = pool.balanceOf(a);
        uint256 balBefore = weth.balanceOf(a);

        vm.prank(a);
        try pool.withdraw(amount, a, a) {
            uint256 got = weth.balanceOf(a) - balBefore;
            _checkPayout(sharesBefore - pool.balanceOf(a), got, a0, s0);
            _modelAfterWithdraw(a, got);
            if (wasPaused) ghost_withdrawalsWhilePaused++;
            if (_priceDropped(a0, s0, _realBal(), pool.totalSupply())) ghost_priceDroppedOnUserAction = true;
        } catch {
            // amount <= maxWithdraw, so this must never fail - paused or not
            ghost_validWithdrawReverted = true;
        }
    }

    function redeem(uint256 actorSeed, uint256 shares) public {
        address a = _actor(actorSeed);
        uint256 maxR = pool.maxRedeem(a);
        if (maxR == 0) return;
        shares = bound(shares, 1, maxR);
        bool wasPaused = pool.paused();
        uint256 a0 = _realBal();
        uint256 s0 = pool.totalSupply();
        uint256 balBefore = weth.balanceOf(a);

        vm.prank(a);
        try pool.redeem(shares, a, a) {
            uint256 got = weth.balanceOf(a) - balBefore;
            _checkPayout(shares, got, a0, s0);
            _modelAfterWithdraw(a, got);
            if (wasPaused) ghost_withdrawalsWhilePaused++;
            if (_priceDropped(a0, s0, _realBal(), pool.totalSupply())) ghost_priceDroppedOnUserAction = true;
        } catch {
            // shares <= maxRedeem, so this must never fail - paused or not
            ghost_validWithdrawReverted = true;
        }
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address a = _actor(actorSeed);
        bool wasPaused = pool.paused();
        if (wasPaused) ghost_depositAttemptsWhilePaused++;
        uint256 maxM = pool.maxMint(a);
        // half the time stay within maxMint, otherwise allow overshooting by up to 2x
        shares = bound(shares, 1, (maxM == 0 ? 1e6 : maxM) * (actorSeed % 2 == 0 ? 1 : 2));
        uint256 cost = pool.previewMint(shares);
        bool allowed = _modelDepositAllowed(a, cost);
        weth.mint(a, cost);
        uint256 a0 = _realBal();
        uint256 s0 = pool.totalSupply();
        uint256 userBefore = weth.balanceOf(a);
        vm.prank(a);
        try pool.mint(shares, a) {
            uint256 paid = userBefore - weth.balanceOf(a);
            ghost_wethIn += paid;
            if (!allowed) ghost_invalidDepositSucceeded = true;
            else ghost_validDepositsSucceeded++;
            if (wasPaused) ghost_depositSucceededWhilePaused = true;
            if (modelTotalPrincipal + paid > 100 ether) ghost_depositBrokeTotalCap = true;
            _modelAfterDeposit(a, paid);
            if (_priceDropped(a0, s0, _realBal(), pool.totalSupply())) ghost_priceDroppedOnUserAction = true;
        } catch {
            if (allowed) ghost_validDepositReverted = true;
        }
    }

    /// a spender withdraws on the owner's behalf (allowance) and sends WETH to itself
    function withdrawViaAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address o = _actor(ownerSeed);
        address sp = _actor(spenderSeed);
        if (o == sp) return;
        uint256 maxW = pool.maxWithdraw(o);
        if (maxW == 0) return;
        amount = bound(amount, 1, maxW);
        vm.prank(o);
        pool.approve(sp, type(uint256).max);
        bool wasPaused = pool.paused();
        uint256 a0 = _realBal();
        uint256 s0 = pool.totalSupply();
        uint256 sharesBefore = pool.balanceOf(o);
        uint256 balBefore = weth.balanceOf(sp);
        vm.prank(sp);
        try pool.withdraw(amount, sp, o) {
            uint256 got = weth.balanceOf(sp) - balBefore;
            _checkPayout(sharesBefore - pool.balanceOf(o), got, a0, s0);
            _modelAfterWithdraw(o, got);
            if (wasPaused) ghost_withdrawalsWhilePaused++;
            if (_priceDropped(a0, s0, _realBal(), pool.totalSupply())) ghost_priceDroppedOnUserAction = true;
        } catch {
            ghost_validWithdrawReverted = true;
        }
    }

    /// direct WETH donation by an outsider (inflation-style manipulation)
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        weth.mint(address(this), amount);
        assertTrue(weth.transfer(address(pool), amount));
        ghost_wethIn += amount;
    }

    /// Coverage: make sure many deposits happen in an open pool, so the
    /// "allowed deposits must succeed" check is exercised often, not only by chance.
    function depositWhileOpen(uint256 actorSeed, uint256 amount) external {
        if (pool.paused()) {
            vm.prank(owner);
            pool.unpause();
        }
        address a = _actor(actorSeed);
        uint256 room = _modelRoom(a);
        if (room == 0) return;
        _depositExact(a, bound(amount, 1, room));
    }

    // --------------------------------------------------------- forced-pause variants
    // Make sure the "paused" branch is exercised often, not only by chance.

    function _ensurePaused() internal {
        if (!pool.paused()) {
            vm.prank(owner);
            pool.pause();
        }
    }

    function depositWhilePaused(uint256 actorSeed, uint256 amount) external {
        _ensurePaused();
        deposit(actorSeed, amount);
    }

    function withdrawWhilePaused(uint256 actorSeed, uint256 amount) external {
        _ensurePaused();
        withdraw(actorSeed, amount);
    }

    function redeemWhilePaused(uint256 actorSeed, uint256 shares) external {
        _ensurePaused();
        redeem(actorSeed, shares);
    }

    // --------------------------------------------------------- owner actions

    function simulateGain(uint256 amount) external {
        amount = bound(amount, 1, 10 ether);
        weth.mint(owner, amount);
        vm.prank(owner);
        pool.simulateGain(amount);
        ghost_wethIn += amount;
    }

    function simulateLoss(uint256 bps) external {
        uint256 assets = _realBal();
        if (assets == 0) return;
        // mostly partial losses; a total loss stays possible but rarer, so the pool is not
        // permanently closed by R8 in most runs
        bps = bps % 10 == 0 ? bound(bps, 1, 10_000) : bound(bps, 1, 5_000);
        uint256 amount = assets * bps / 10_000;
        if (amount == 0) return;
        vm.prank(owner);
        pool.simulateLoss(amount);
        ghost_wethOut += amount;
        ghost_losses++;
    }

    function togglePause() external {
        bool isPaused = pool.paused(); // read first: vm.prank only applies to the next call
        vm.prank(owner);
        if (isPaused) pool.unpause();
        else pool.pause();
    }
}
