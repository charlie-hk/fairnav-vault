// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FairNAVVault
/// @notice Educational, TESTNET-ONLY, UNAUDITED ERC-4626 pool with hard risk limits.
///         Rules (see README for the full specification):
///         R1 Total principal: a deposit may not take totalPrincipal above TOTAL_CAP (100 WETH).
///            Measured on money deposited, not on the balance, so donations cannot close the pool.
///         R2 Per wallet: a wallet's net principal may not exceed WALLET_CAP (5 WETH).
///         R3 Withdrawals are instant, at most MAX_WITHDRAW_PER_TX (5 WETH) of assets per call.
///         R4 Pause blocks deposits and mints only. Withdraw and redeem can never be paused.
///         R5 Fair share: an account can only ever receive
///            shares * (totalAssets + 1) / (totalSupply + 10**OFFSET), rounded down.
///         R6 Shares are non-transferable, so caps cannot be bypassed by moving shares.
///         R7 No real investments: the owner can only simulate gains (send WETH in) and
///            losses (send WETH to a burn address). The owner can never send pool assets to itself.
///         R8 Failed-pool lock: deposits close while the share price is below 1% of the launch
///            price. Stops share-supply blow-up after near-total losses. Withdrawals stay open.
///         R9 Self-deposit only: the receiver of a deposit must be the caller (blocks 1-wei griefing
///            that would fill someone else's wallet cap). A full exit resets the wallet counter.
///         R10 Testnet only: the constructor reverts on any chain not in the testnet allowlist.
contract FairNAVVault is ERC4626, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant TOTAL_CAP = 100 ether;
    uint256 public constant WALLET_CAP = 5 ether;
    uint256 public constant MAX_WITHDRAW_PER_TX = 5 ether;
    uint8 public constant OFFSET = 6;
    /// @dev Launch price is 1 wei of asset per 10**OFFSET shares; R8 floor is 1% of that.
    uint256 public constant MIN_PRICE_DIVISOR = 100;
    address public constant LOSS_SINK = 0x000000000000000000000000000000000000dEaD;

    /// @notice Net principal per wallet: deposits minus withdrawn assets, floored at zero.
    mapping(address => uint256) public netDeposited;

    /// @notice Sum of all wallets' net principal. R1 is measured on this, never on the balance.
    uint256 public totalPrincipal;

    event GainSimulated(uint256 amount, uint256 totalAssetsAfter);
    event LossSimulated(uint256 amount, uint256 totalAssetsAfter);

    error SharesNonTransferable();
    error TotalCapExceeded();
    error WalletCapExceeded();
    error WithdrawLimitExceeded();
    error LossExceedsAssets();
    error ZeroAmount();
    error PoolFailedDepositsClosed();
    error ReceiverMustBeCaller();
    error RenounceDisabled();
    error NotATestnet(uint256 chainId);

    constructor(IERC20 weth, address initialOwner)
        ERC20("FairNAV Vault Share", "fnvWETH")
        ERC4626(weth)
        Ownable(initialOwner)
    {
        if (!isTestnet(block.chainid)) revert NotATestnet(block.chainid);
    }

    /// @notice R10 allowlist. Anything not listed, including every mainnet, is rejected.
    function isTestnet(uint256 chainId) public pure returns (bool) {
        return chainId == 31337 // Anvil / local
            || chainId == 11155111 // Ethereum Sepolia
            || chainId == 560048 // Ethereum Hoodi
            || chainId == 84532 // Base Sepolia
            || chainId == 421614 // Arbitrum Sepolia
            || chainId == 11155420 // OP Sepolia
            || chainId == 80002 // Polygon Amoy
            || chainId == 97; // BNB Chain testnet
    }

    // ---------------------------------------------------------------- limits

    function _decimalsOffset() internal pure override returns (uint8) {
        return OFFSET;
    }

    /// @notice R8: false once the share price has fallen below 1% of the launch price.
    ///         price = (totalAssets + 1) / (totalSupply + 10**OFFSET); launch = 1 / 10**OFFSET.
    function depositsOpen() public view returns (bool) {
        return (totalAssets() + 1) * (10 ** OFFSET) * MIN_PRICE_DIVISOR >= totalSupply() + 10 ** OFFSET;
    }

    /// @dev R1 + R2 + R4 + R8. Returns 0 while paused or after the pool has failed.
    ///      Not expressible here: R9 (a deposit sent by someone else for `receiver` reverts)
    ///      and a deposit too small to mint at least one share reverts. See README.
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused() || !depositsOpen()) return 0;
        uint256 roomTotal = totalPrincipal >= TOTAL_CAP ? 0 : TOTAL_CAP - totalPrincipal;
        uint256 principal = netDeposited[receiver];
        uint256 roomWallet = principal >= WALLET_CAP ? 0 : WALLET_CAP - principal;
        return Math.min(roomTotal, roomWallet);
    }

    /// @dev Rounds down, so minting maxMint shares never costs more than maxDeposit assets.
    function maxMint(address receiver) public view override returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @dev R3. Deliberately ignores the pause flag (R4).
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), MAX_WITHDRAW_PER_TX);
    }

    /// @dev R3. Rounds down, so redeeming maxRedeem shares never pays more than the per-tx limit.
    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(balanceOf(owner), _convertToShares(MAX_WITHDRAW_PER_TX, Math.Rounding.Floor));
    }

    // ---------------------------------------------------------------- hooks

    /// @dev Second line of defence: the caps are re-checked here even though
    ///      ERC4626.deposit/mint already check maxDeposit/maxMint.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        if (assets == 0 || shares == 0) revert ZeroAmount();
        if (!depositsOpen()) revert PoolFailedDepositsClosed();
        if (receiver != caller) revert ReceiverMustBeCaller();
        if (totalPrincipal + assets > TOTAL_CAP) revert TotalCapExceeded();
        if (netDeposited[receiver] + assets > WALLET_CAP) revert WalletCapExceeded();
        netDeposited[receiver] += assets;
        totalPrincipal += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev No pause check here on purpose: withdrawals can never be blocked.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets > MAX_WITHDRAW_PER_TX) revert WithdrawLimitExceeded();
        uint256 principal = netDeposited[owner];
        uint256 reduce = assets >= principal ? principal : assets;
        // a wallet that fully exits starts fresh, even if it exited at a loss
        if (balanceOf(owner) == shares) reduce = principal;
        // state before the token transfer (checks-effects-interactions)
        netDeposited[owner] = principal - reduce;
        totalPrincipal -= reduce;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev R6. Only mint (from == 0) and burn (to == 0) are allowed.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert SharesNonTransferable();
        super._update(from, to, value);
    }

    // ---------------------------------------------------------------- simulation (R7)

    /// @notice Simulate investment profit: the owner sends `amount` WETH into the pool.
    function simulateGain(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit GainSimulated(amount, totalAssets());
    }

    /// @notice Simulate investment loss: `amount` WETH is sent to a burn address, never to the owner.
    function simulateLoss(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (amount > totalAssets()) revert LossExceedsAssets();
        IERC20(asset()).safeTransfer(LOSS_SINK, amount);
        emit LossSimulated(amount, totalAssets());
    }

    // ---------------------------------------------------------------- admin

    /// @notice Blocks deposits and mints only.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled: an owner renouncing while paused would close deposits forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---------------------------------------------------------------- views

    /// @notice Assets `account` could receive if it exited fully, ignoring the per-tx limit.
    function fairShareOf(address account) external view returns (uint256) {
        return _convertToAssets(balanceOf(account), Math.Rounding.Floor);
    }
}
