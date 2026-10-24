# YieldFarmingPool

## Overview

**YieldFarmingPool** is a multi-pool staking contract. The owner creates pools, each one accepting a different ERC20 token, and users stake that token to earn a second token (the reward token) over time.

Rewards are accounted with the standard *reward-per-token accumulator* pattern, so the contract never loops over users: each pool keeps one running number (`rewardPerTokenStored`), and each user keeps a marker (`rewardDebt`) of how much of that number they have already been paid for. Every pool is identified by a `bytes32` ID built with `keccak256(abi.encodePacked(token, rewardRate, block.timestamp, block.chainid))`.

The contract uses OpenZeppelin's `Ownable`, `ReentrancyGuard` and `SafeERC20`. The test suite covers every function and every `require` path and reaches 100% line, statement, branch and function coverage. All expected values in the tests (rewards, balances, reward debt, packed bytes) are worked out by hand, never copied from the contract's own output.

## How it works

- [`YieldFarmingPool.sol`](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol) — the staking contract
- [`MockToken.sol`](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/MockToken/MockToken.sol) — ERC20 used for staking and rewards in tests
- [`YieldFarmingPool.t.sol`](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/test/YieldFarmingPool.t.sol) — Foundry tests for the pool
- [`MockToken.t.sol`](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/test/MockToken.t.sol) — Foundry tests for the mock token

**Reward math.** While a pool has stakers, every second it adds `rewardRate` tokens to be shared among them. The pool converts that into "reward per staked token" (scaled by 1e18) and stores it. A user's pending reward is:

```
amount * rewardPerTokenStored / 1e18 - rewardDebt
```

Two users in the same pool split rewards in proportion to what they staked. The owner can change a pool's rate at any time: the time already elapsed is settled at the old rate first, and the new rate only applies from that moment on.

**Safe payouts.** Rewards are paid from the contract's own reward-token balance. If that balance is lower than what a user is owed, `_safeRewardTransfer` pays what is available instead of reverting.

## Functions

| Function | What it does | Access |
|---|---|---|
| `constructor` | Sets the reward token and the owner | deployer |
| `createPool` | Opens a pool for a token with a reward rate and returns its ID | owner |
| `stake` | Deposits tokens into a pool; pays any pending rewards first | anyone |
| `withdraw` | Returns staked tokens and pays pending rewards | anyone |
| `claimRewards` | Pays pending rewards without touching the stake | anyone |
| `updatePoolRewardRate` | Changes a pool's reward rate after settling the old one | owner |
| `pendingRewards` | Shows a user's unclaimed rewards without changing state | view |
| `getPoolEncodedData` | Packs a pool's data into compact bytes | view |
| `getUserHash` | Builds a unique hash for a user in a pool | pure |
| `getActivePoolsCount` | Number of pools created | view |
| `getActivePools` | List of all pool IDs | view |
| `emergencyWithdraw` | Sends any token held by the contract to the owner | owner |

## Technical docs

*(Function-by-function documentation with links to the source: coming next.)*

## Observations found by testing

Writing the tests surfaced several design behaviors worth knowing. None of them break the contract's accounting, but each one is a decision a production version would revisit:

- **Pools can never be closed.** `isActive` is set to `true` on creation and never set back to `false`, so the "Pool is not active" check only rejects pools that do not exist.
- **`withdraw` does not check the pool state.** Users can always exit, which is safe, but it is inconsistent with `stake`.
- **The owner can move user funds.** `emergencyWithdraw` accepts any token, including the tokens users have staked.
- **Underfunded rewards are lost, not deferred.** If the reward balance is short, the user is paid what is available but `rewardDebt` still advances by the full amount, so the unpaid part cannot be claimed later.
- **`withdraw` leaves `lastClaimTime` untouched**, while `stake` and `claimRewards` update it.
- **`activePools` only grows.** Pool IDs are never removed from the list.

## Tech

- Solidity `^0.8.19`
- Foundry (forge, forge-std)
- OpenZeppelin Contracts v5 (`Ownable`, `ReentrancyGuard`, `SafeERC20`, `ERC20`)

## Testing

35 tests (31 for the pool, 4 for the mock token), covering happy paths, every revert and the edge cases around time (`vm.warp`), reward accrual and underfunded payouts.

```bash
forge test
forge coverage
```

| File | % Lines | % Statements | % Branches | % Funcs |
|---|---|---|---|---|
| `src/MockToken/MockToken.sol` | 100.00% (6/6) | 100.00% (3/3) | 100.00% (0/0) | 100.00% (3/3) |
| `src/YieldFarmingPool.sol` | 100.00% (99/99) | 100.00% (100/100) | 100.00% (26/26) | 100.00% (15/15) |
| **Total** | **100.00% (105/105)** | **100.00% (103/103)** | **100.00% (26/26)** | **100.00% (18/18)** |
