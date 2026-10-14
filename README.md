![FairNAV Vault](assets/cover.png)

# FairNAV Vault

[![tests](../../actions/workflows/test.yml/badge.svg)](../../actions/workflows/test.yml)

An ERC-4626 investment pool in Solidity that pays every investor their fair share of the pool's net asset value (NAV), with the risk rules written into the contract itself: hard deposit caps, a per-withdrawal limit, withdrawals that can never be frozen, and a fair-share guarantee that keeps holding after the pool loses money. Every rule is covered by unit, fuzz and invariant tests in Foundry.

**What this is, and what it is not.** This is an *accounting simulator*: it shows how shares, caps and losses are handled correctly. It is not a working DeFi fund. There is no investment strategy; gains and losses are entered by the owner to exercise the accounting.

> **Educational project. Testnet only. Unaudited.**
> This code has not been reviewed by a security auditor. Do not put real funds in it. The contract itself refuses to deploy outside a testnet allowlist (R10).

## Risk rules

All amounts are in WETH (18 decimals). "Assets" means WETH held by the pool; "shares" are the pool's ERC-20 shares (`fnvWETH`).

| # | Rule | Exact behaviour |
|---|------|-----------------|
| R1 | **Pool cap: 100 WETH of principal** | A deposit is rejected if `totalPrincipal + amount > 100 WETH`, where `totalPrincipal` is the sum of all wallets' net principal (see R2). The cap is measured on money deposited, not on the pool's balance, so gains or direct donations never close deposits. |
| R2 | **Wallet cap: 5 WETH of net principal** | Each wallet has a counter (`netDeposited`): deposits add the amount, withdrawals subtract the assets paid out, floored at zero, and a full exit resets it to zero. A deposit is rejected if the counter would exceed 5 WETH. This caps *money put in*, not current value: after a gain a wallet can hold more than 5 WETH, and withdrawing 5 then re-depositing 5 is allowed. |
| R3 | **Withdrawals: instant, max 5 WETH per transaction** | `withdraw` and `redeem` settle immediately, with no queue or delay. One call can pay out at most 5 WETH; a larger position exits over several calls. |
| R4 | **Pause blocks deposits only** | The owner can pause. While paused, `deposit` and `mint` revert and `maxDeposit`/`maxMint` return 0. `withdraw` and `redeem` have no pause check and can never be blocked. |
| R5 | **Fair share** | An account can receive at most `shares × (totalAssets + 1) / (totalSupply + 10^6)`, rounded down. This is the ERC-4626 formula with a virtual offset of 10^6 shares and 1 wei. It is never more than the plain pro-rata amount `shares × totalAssets / totalSupply` plus 1 wei of rounding. |
| R6 | **Shares are non-transferable** | Shares can only be minted (deposit) or burned (withdraw). Without this, R2 could be bypassed by moving shares to a full wallet. |
| R7 | **Simulated investing only** | No external protocol is used. The owner can `simulateGain` (send WETH in) or `simulateLoss` (send WETH to the burn address `0x…dEaD`). A loss can never send pool assets to the owner. |
| R8 | **Failed-pool lock** | Deposits close while the share price is below 1% of the launch price, i.e. when `(totalAssets + 1) × 10^6 × 100 < totalSupply + 10^6`. Withdrawals stay open. A gain that lifts the price back above the floor reopens deposits. |
| R9 | **Self-deposit only** | The receiver of a deposit or mint must be the caller. Otherwise anyone could deposit 1 wei "for" another wallet and use up its cap. Because of this, `maxDeposit(x)` describes what `x` itself can deposit; a deposit sent by someone else for `x` reverts. Withdrawals on someone's behalf through an ERC-20 allowance still work. |
| R10 | **Testnet only** | The constructor reverts on any chain id outside this allowlist: 31337 (local Anvil), 11155111 (Sepolia), 560048 (Hoodi), 84532 (Base Sepolia), 421614 (Arbitrum Sepolia), 11155420 (OP Sepolia), 80002 (Polygon Amoy), 97 (BNB Chain testnet). Every mainnet is rejected by the contract itself, not only by the deploy script. Testnet ids checked against the [Etherscan supported-chains list](https://docs.etherscan.io/supported-chains). |

### Why R8, R9 and R10 exist

None of them was in the original spec.

The code went through three rounds of AI-assisted code review. No human security auditor has looked at it.

- **Round 1** led to R9, the counter reset in R2, and disabling `renounceOwnership`.
- **Round 2** led to R10. The first deploy script only blocked Ethereum mainnet (chain id 1), so "testnet only" was a claim, not a rule. It also led to the near-total-loss tests and to invariants that check the real WETH balance instead of the contract's own formula.
- **Round 3** found that R1 was measured on the pool's balance. One wallet could deposit 5 WETH, donate 95 WETH directly, close deposits for everyone, and then withdraw almost all of it back. R1 is now measured on principal, and `test/CapGriefing.t.sol` reproduces the attack. This round also led to two-step ownership transfer, and to invariant checks that allowed deposits really succeed.

R8 was added after the invariant tests found a real problem: after repeated near-total losses, each new deposit mints shares at a collapsed price, so the share supply multiplies on every cycle. In one test sequence it reached about 10^60 shares, and the share math then overflowed and reverted. With the 1% price floor, new shares are only ever minted at a sane price, and the supply stays bounded.

### Why withdrawals can never be paused

A pause switch that also freezes withdrawals lets an operator trap users' funds. Here the owner can stop new money from coming in, but every holder can always exit with their fair share.

### First-depositor (inflation) attack

The classic ERC-4626 attack: deposit 1 wei, donate a large amount directly to the pool to inflate the share price, and let the next depositor's shares round down to almost nothing. The 10^6 virtual-share offset (`_decimalsOffset() = 6`) makes this unprofitable. In the unit test, an attacker who deposits 1 wei and donates 10 WETH can claim back only about 5 WETH of the 10 WETH it put in, while the victim's 5 WETH deposit loses about 0.0000033 WETH (0.67 parts per million) to rounding. The fuzz test checks this across donations of up to 95 WETH.

## Fund-management parallels

I have worked in financial markets for 20 years and hold a master's degree in finance. I set the core rules of this pool (the caps, instant withdrawals and the fair-share requirement after losses) from a fund-management point of view; the later rules came out of testing and code review, as described above. Each rule has a direct equivalent in fund management:

| Pool rule | Fund-management equivalent |
|-----------|----------------------------|
| R1: 100 WETH pool cap | Fund capacity limit, or a soft close to new investors |
| R2: 5 WETH per wallet | Concentration limit on a single investor |
| R3: 5 WETH per withdrawal | Redemption limits (gating) |
| R4: withdrawals never pausable | Investor protection against redemption suspensions |
| R5: fair share = shares × assets / supply | NAV per unit and pro-rata redemption |
| R8: failed-pool lock | Closing a fund to new money after a NAV collapse |
| Exit-before-loss limitation | Stale-NAV arbitrage, the market-timing problem in mutual funds |

**What a finance background adds to a contract like this:**

- **The rules are treated as investor protections, not as code features.** Each rule answers the question a fund prospectus answers: what protects the investor who is still in the fund? That is why withdrawals stay open under pause and why the operator can never receive the pool's assets.
- **The loss-timing limitation is treated as a known fund problem, not dismissed as an edge case.** Exiting just before a loss is booked is similar to stale-price market timing in mutual funds. The SEC notes that market timing itself is not illegal, but when traders exploit prices that do not yet reflect current value, it "may dilute the value of long-term shareholders' interests" and give redeeming shareholders "a windfall at the expense of the shareholders that remain in the fund" ([SEC Release 33-8343, Dec. 17, 2003](https://www.sec.gov/files/rules/proposed/33-8343.pdf); see also [SEC testimony of Paul F. Roye, Nov. 3, 2003](https://www.sec.gov/news/testimony/ts110303pfr.htm)). The mechanism here is different (a pending loss transaction rather than a stale daily NAV), but the effect on remaining investors is the same. A pure smart-contract view sees a front-running quirk; a fund view sees a fairness failure, which is why it is tested and documented here instead of hidden.
- **Fair share is defined the way a fund defines it.** Redemptions are at NAV per unit at the moment of the transaction, and the remaining investors must never be diluted by someone else's exit. Two of the invariant tests (`invariant_UsersCannotDiluteOthers` and `invariant_EveryoneCanExitFully`) encode exactly that.

## ERC-4626 deviations

The pool uses OpenZeppelin's ERC-4626 implementation but is **not fully standard-compliant**, on purpose:

- `maxDeposit(x)` and `maxMint(x)` describe what wallet `x` can deposit *for itself*. A deposit sent by another address for `x` reverts (R9), even though `maxDeposit(x)` is above zero. The standard expects `maxDeposit` to be an amount that will not revert.
- A deposit so small that it would mint zero shares reverts. `maxDeposit` cannot express a minimum.
- Shares cannot be transferred (R6), so integrations that move vault shares around will not work.

`maxWithdraw` and `maxRedeem` are exact: an amount at or below them never reverts, paused or not, and that is tested.

## What is guaranteed, and what is not

Guaranteed by the contract and checked by tests:

- No withdrawal or redeem pays out more than the caller's pro-rata share of the pool's *real* WETH balance (1 wei rounding tolerance).
- Everyone can always exit completely, and the total paid out never exceeds the real WETH balance, including after a near-total loss. If the pool is left with 1 wei or nothing at all, every holder can still redeem and burn all their shares; nobody's transaction reverts because an earlier exit took too much. The reason: the sum of all claims is at most `⌊S × (A + 1) / (S + 10^6)⌋`, which is always ≤ `A` (`A` = real assets, `S` = share supply).
- Deposits, withdrawals and redeems by users never lower the share price for others. Only a simulated loss can.
- R1 to R4 and R6 hold in every tested sequence.

**Not** guaranteed:

- **Losses in the investment itself.** The fair-share rule divides losses fairly. It does not prevent them.
- **Losses are shared by the people still in the pool when the loss lands.** Losses here are single transactions. A holder who exits before the loss transaction is mined keeps the old price, for example by watching the mempool, and the remaining holders carry the whole loss. The fair-share rule holds at the moment of every withdrawal, not across a loss event. This is similar to the stale-price timing problem real funds have with NAV updates (see Fund-management parallels). Fixing it needs a withdrawal delay or continuous valuation, which conflicts with the "instant withdrawals" rule. `test_KnownLimitation_ExitBeforeLossAvoidsIt` demonstrates it. Likewise, depositing just before a simulated gain earns part of that gain.
- **Owner trust.** The owner can simulate a loss of up to 100% of the pool. Ownership transfer is two-step (`Ownable2Step`): the new owner must call `acceptOwnership`, so a mistyped address cannot take over. `renounceOwnership` is disabled, because renouncing while paused would close deposits forever. This is a demo of the accounting, not a trustless fund. In a real product, the strategy would be a separate contract with its own limits.
- **Pool cap is first come, first served.** When the pool is near 100 WETH, an earlier transaction can take the remaining room.
- **Sybil resistance.** The 5 WETH wallet cap is per address. One person with many wallets can deposit more. Real per-person limits need identity (KYC/allowlist), which is out of scope.
- **Security.** Unaudited. Tests reduce risk but do not prove the absence of bugs.

## Tests

58 tests, all passing. A test count is not a proof of security; what matters is what the tests check and whether they can fail. Both are described below.

- **36 unit and fuzz tests** (`test/FairNAVVault.t.sol`): caps at their exact boundaries, the per-transaction limit, pause behaviour, non-transferable shares, self-deposit only, withdrawals through an allowance, two-step ownership, pro-rata loss sharing, total-loss handling, the price floor, the inflation attack, and the known loss-timing limitation. 4 fuzz tests, 1,000 random cases each.
- **1 cap-griefing test** (`test/CapGriefing.t.sol`): a 5 WETH deposit plus a 95 WETH donation must not close deposits for others.
- **4 near-total-loss tests** (`test/NearTotalLoss.t.sol`): the pool is left with 1 wei, or with nothing, and every holder must exit fully. The fuzz version uses 1 to 12 holders, any deposit sizes, 0 to 1,000 wei left and a random exit order (1,000 cases).
- **5 deployment tests** (`test/Deploy.t.sol`): the script and the contract both refuse six mainnets (Ethereum, BNB Chain, Polygon, Base, Arbitrum, OP), the script refuses a WETH address without code, the owner is checked after deployment, and a fuzz test confirms the contract deploys on exactly the allowlisted chain ids and no others.
- **12 invariant tests** (`test/invariant/`): a handler drives random sequences of deposits, mints, withdrawals, redeems, withdrawals through an allowance to another receiver, donations, gains, losses and pause toggles across 6 users (256 runs × 100 calls each). `fail_on_revert` is on, so a handler call that reverts unexpectedly fails the suite.

### The checks do not trust the contract's own math

The fair-share and solvency checks never use the contract's conversion functions (`convertToAssets`, `totalAssets`, `fairShareOf`). They work from the real WETH balance, read from the token:

- every payout is compared with `shares × realBalance / supply`, calculated in the test;
- the handler keeps its own ledger of every WETH unit that entered or left the pool, and the pool's real balance must always equal that ledger;
- `invariant_EveryoneCanExitFully` takes a snapshot of the state, makes every holder exit completely, checks that nothing reverted and that the total paid did not exceed the real balance, and then restores the state.
- the handler keeps its own model of each wallet's principal, written from the rules above. Every deposit or mint the model allows must succeed, every one it forbids must revert, and the contract's `netDeposited` and `totalPrincipal` must match the model.

### Can the tests fail?

Tests that pass no matter what prove nothing, so the suite was run against three deliberately broken versions of the contract. The correct contract was restored after each run.

| Broken version | Result |
|----------------|--------|
| Every withdrawal overpays by 1% | 16 of 58 tests failed, including the near-total-loss fuzz test and four invariants (`EveryoneCanExitFully`, `NoPayoutAboveFairShare`, `UsersCannotDiluteOthers`, `WithdrawalsAlwaysAvailable`) |
| R1 measured on the balance again (the round 3 bug) | 2 of 57 tests failed (same run): the cap-griefing test and `test_TotalCap_GainsDoNotCloseDeposits`. The invariants did **not** catch this one. |
| Wallet cap silently lowered to 4 WETH | 26 of 57 tests failed (run before the two-step ownership test was added), including `invariant_DepositsFollowTheRules` ("an allowed deposit reverted") |

Coverage note: in the last invariant runs, between 4 and 16 of the 100 calls per run were deposits that the rules allowed. The rest were withdrawals, losses, pauses and deposits that the rules forbid. This was measured from the printed counters of 12 runs, not of all 256.

| Invariant | Rule |
|-----------|------|
| `invariant_NoPayoutAboveFairShare` | R5 |
| `invariant_EveryoneCanExitFully` | R5 (solvency) |
| `invariant_RealBalanceMatchesLedger` | R5, R7 |
| `invariant_UsersCannotDiluteOthers` | R5 |
| `invariant_TotalCapAtDeposit` | R1 |
| `invariant_PrincipalMatchesModel` | R1, R2 |
| `invariant_DepositsFollowTheRules` | R1, R2, R4, R8, R9 |
| `invariant_WalletCap` | R2 |
| `invariant_PerTxWithdrawLimit` | R3 |
| `invariant_PauseBlocksDeposits` | R4 |
| `invariant_WithdrawalsAlwaysAvailable` | R4 |
| `invariant_SupplyMatchesHolders` | R6 |

The invariant tests do not cover the loss-timing limitation above. It is a property of instant withdrawals, not a bug the invariants could catch.

### Independent verification

Every push runs the full suite on GitHub's servers (`.github/workflows/test.yml`), with the dependencies pinned to forge-std v1.17.0 and OpenZeppelin v5.1.0. The badge at the top shows the latest result.

## Run it

```bash
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
forge test               # all 58 tests
forge test -vv --mt invariant_   # invariants, with coverage counters printed
```

## Deploy to a testnet

```bash
WETH=<testnet WETH address> forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --account <keystore-name> --broadcast
```

The deployer becomes the owner. Before broadcasting, the script refuses any chain outside the R10 allowlist and any WETH address without code. After deployment, it checks the owner, the asset and that the pool is not paused. The contract enforces the same allowlist in its constructor, so it cannot reach a mainnet even if the script is bypassed.

## Layout

```
src/FairNAVVault.sol                            the vault
test/FairNAVVault.t.sol                         unit + fuzz tests
test/CapGriefing.t.sol                          donation cap-griefing test
test/NearTotalLoss.t.sol                        near-total-loss exit tests
test/Deploy.t.sol                               deployment and chain allowlist tests
test/invariant/Handler.sol                      random action handler with ghost variables
test/invariant/FairNAVVault.invariant.t.sol     invariant tests
test/mocks/MockWETH.sol                         mintable WETH for tests
script/Deploy.s.sol                             testnet deploy script
.github/workflows/test.yml                      CI: build and run all tests on every push
```

## Stack

Solidity 0.8.24, Foundry, OpenZeppelin Contracts 5.1 (ERC4626, Ownable2Step, Pausable, SafeERC20).

## License

MIT
