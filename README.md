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

### YieldFarmingPool

#### `constructor`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L57-L60)

```solidity
/**
 * @dev Contract constructor
 * @param _rewardToken Address of the reward token
 */
constructor(address _rewardToken) Ownable(msg.sender) {
    require(_rewardToken != address(0), "Invalid reward token");
    rewardToken = IERC20(_rewardToken);
}
```

#### `createPool`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L71-L94)

```solidity
/**
 * @dev Creates a new yield farming pool
 * @param token Address of the token to stake
 * @param rewardRate Reward rate per second
 * @return poolId Unique pool identifier
 *
 * IMPORTANT: This method demonstrates the use of abi.encodePacked to create
 * unique identifiers by combining multiple parameters
 */
function createPool(address token, uint256 rewardRate) external onlyOwner returns (bytes32 poolId) {
    require(token != address(0), "Invalid token address");
    require(rewardRate > 0, "Reward rate must be positive");

    // USAGE OF ABI.ENCODEPACKED: Create a unique identifier for the pool
    // We combine the token address, reward rate, and timestamp
    // to create a unique hash that identifies the pool
    poolId = keccak256(abi.encodePacked(token, rewardRate, block.timestamp, block.chainid));

    require(pools[poolId].token == address(0), "Pool already exists");

    pools[poolId] = Pool({
        token: token,
        totalStaked: 0,
        rewardRate: rewardRate,
        lastUpdateTime: block.timestamp,
        rewardPerTokenStored: 0,
        isActive: true
    });

    activePools.push(poolId);

    emit PoolCreated(poolId, token, rewardRate);
}
```

#### `stake`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L101-L127)

```solidity
/**
 * @dev Stake tokens in a specific pool
 * @param poolId Pool identifier
 * @param amount Amount of tokens to stake
 */
function stake(bytes32 poolId, uint256 amount) external nonReentrant {
    Pool storage pool = pools[poolId];
    require(pool.isActive, "Pool is not active");
    require(amount > 0, "Amount must be positive");

    _updatePool(poolId);

    UserInfo storage user = userInfo[poolId][msg.sender];

    if (user.amount > 0) {
        uint256 pending = _calculatePendingRewards(poolId, msg.sender);
        if (pending > 0) {
            _safeRewardTransfer(msg.sender, pending);
            emit RewardClaimed(poolId, msg.sender, pending);
        }
    }

    IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);

    user.amount += amount;
    user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;
    user.lastClaimTime = block.timestamp;

    pool.totalStaked += amount;

    emit Staked(poolId, msg.sender, amount);
}
```

#### `withdraw`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L134-L156)

```solidity
/**
 * @dev Withdraw staked tokens from a pool
 * @param poolId Pool identifier
 * @param amount Amount of tokens to withdraw
 */
function withdraw(bytes32 poolId, uint256 amount) external nonReentrant {
    Pool storage pool = pools[poolId];
    UserInfo storage user = userInfo[poolId][msg.sender];

    require(user.amount >= amount, "Insufficient staked amount");

    _updatePool(poolId);

    uint256 pending = _calculatePendingRewards(poolId, msg.sender);
    if (pending > 0) {
        _safeRewardTransfer(msg.sender, pending);
        emit RewardClaimed(poolId, msg.sender, pending);
    }

    user.amount -= amount;
    user.rewardDebt = user.amount * pool.rewardPerTokenStored / 1e18;

    pool.totalStaked -= amount;

    IERC20(pool.token).safeTransfer(msg.sender, amount);

    emit Withdrawn(poolId, msg.sender, amount);
}
```

#### `claimRewards`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L162-L175)

```solidity
/**
 * @dev Claim pending rewards
 * @param poolId Pool identifier
 */
function claimRewards(bytes32 poolId) external nonReentrant {
    _updatePool(poolId);

    uint256 pending = _calculatePendingRewards(poolId, msg.sender);
    require(pending > 0, "No rewards to claim");

    UserInfo storage user = userInfo[poolId][msg.sender];
    user.rewardDebt = user.amount * pools[poolId].rewardPerTokenStored / 1e18;
    user.lastClaimTime = block.timestamp;

    _safeRewardTransfer(msg.sender, pending);

    emit RewardClaimed(poolId, msg.sender, pending);
}
```

#### `updatePoolRewardRate`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L182-L190)

```solidity
/**
 * @dev Update the reward rate of a pool
 * @param poolId Pool identifier
 * @param newRewardRate New reward rate
 */
function updatePoolRewardRate(bytes32 poolId, uint256 newRewardRate) external onlyOwner {
    Pool storage pool = pools[poolId];
    require(pool.isActive, "Pool is not active");

    _updatePool(poolId);
    pool.rewardRate = newRewardRate;

    emit PoolUpdated(poolId, newRewardRate);
}
```

#### `pendingRewards`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L198-L211)

```solidity
/**
 * @dev Calculate the pending rewards of a user
 * @param poolId Pool identifier
 * @param user User address
 * @return Amount of pending rewards
 */
function pendingRewards(bytes32 poolId, address user) external view returns (uint256) {
    Pool storage pool = pools[poolId];
    UserInfo storage userInfoData = userInfo[poolId][user];

    uint256 rewardPerTokenStored = pool.rewardPerTokenStored;

    if (pool.totalStaked > 0) {
        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
        uint256 rewards = timeElapsed * pool.rewardRate;
        rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
    }

    return userInfoData.amount * rewardPerTokenStored / 1e18 - userInfoData.rewardDebt;
}
```

#### `getPoolEncodedData`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L221-L228)

```solidity
/**
 * @dev Get encoded pool information for external use
 * @param poolId Pool identifier
 * @return encodedData Encoded pool data
 *
 * DEMONSTRATION: This method shows how to use abi.encodePacked to
 * create compact data that can be used in other contracts
 */
function getPoolEncodedData(bytes32 poolId) external view returns (bytes memory encodedData) {
    Pool storage pool = pools[poolId];

    // Encode the pool data in a compact format
    encodedData = abi.encodePacked(
        pool.token, pool.totalStaked, pool.rewardRate, pool.lastUpdateTime, pool.rewardPerTokenStored, pool.isActive
    );
}
```

#### `getUserHash`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L239-L241)

```solidity
/**
 * @dev Create a unique hash for a user in a specific pool
 * @param poolId Pool identifier
 * @param user User address
 * @return userHash Unique user hash
 *
 * DEMONSTRATION: Use of abi.encodePacked to create unique identifiers
 * by combining multiple parameters
 */
function getUserHash(bytes32 poolId, address user) external pure returns (bytes32 userHash) {
    userHash = keccak256(abi.encodePacked(poolId, user, "YIELD_FARMING_USER"));
}
```

#### `_updatePool (internal)`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L247-L257)

```solidity
/**
 * @dev Update the pool state
 * @param poolId Pool identifier
 */
function _updatePool(bytes32 poolId) internal {
    Pool storage pool = pools[poolId];

    if (pool.totalStaked > 0) {
        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
        uint256 rewards = timeElapsed * pool.rewardRate;
        pool.rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
    }

    pool.lastUpdateTime = block.timestamp;
}
```

#### `_calculatePendingRewards (internal)`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L265-L278)

```solidity
/**
 * @dev Calculate the pending rewards of a user
 * @param poolId Pool identifier
 * @param user User address
 * @return Amount of pending rewards
 */
function _calculatePendingRewards(bytes32 poolId, address user) internal view returns (uint256) {
    Pool storage pool = pools[poolId];
    UserInfo storage userInfoData = userInfo[poolId][user];

    uint256 rewardPerTokenStored = pool.rewardPerTokenStored;

    if (pool.totalStaked > 0) {
        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime;
        uint256 rewards = timeElapsed * pool.rewardRate;
        rewardPerTokenStored += rewards * 1e18 / pool.totalStaked;
    }

    return userInfoData.amount * rewardPerTokenStored / 1e18 - userInfoData.rewardDebt;
}
```

#### `_safeRewardTransfer (internal)`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L285-L293)

```solidity
/**
 * @dev Safely transfer rewards
 * @param to Recipient address
 * @param amount Amount to transfer
 */
function _safeRewardTransfer(address to, uint256 amount) internal {
    uint256 rewardBalance = rewardToken.balanceOf(address(this));
    if (amount > rewardBalance) {
        amount = rewardBalance;
    }
    if (amount > 0) {
        rewardToken.safeTransfer(to, amount);
    }
}
```

#### `getActivePoolsCount`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L299-L301)

```solidity
/**
 * @dev Get the total number of active pools
 * @return Number of active pools
 */
function getActivePoolsCount() external view returns (uint256) {
    return activePools.length;
}
```

#### `getActivePools`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L307-L309)

```solidity
/**
 * @dev Get all active pools
 * @return Array with the identifiers of the active pools
 */
function getActivePools() external view returns (bytes32[] memory) {
    return activePools;
}
```

#### `emergencyWithdraw`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/YieldFarmingPool.sol#L318-L320)

```solidity
/**
 * @dev Sends any token held by the contract to the owner
 * @param token Address of the token to withdraw
 * @param amount Amount of tokens to withdraw
 *
 * WARNING: This can move any token in the contract, including user deposits
 */
function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
    IERC20(token).safeTransfer(owner(), amount);
}
```

### MockToken

#### `constructor`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/MockToken/MockToken.sol#L13-L18)

```solidity
/**
 * @title MockToken
 * @dev Token ERC-20 mock to test the yield farming project
 */
contract MockToken is ERC20, Ownable {
constructor(string memory name, string memory symbol, uint256 initialSupply)
    ERC20(name, symbol)
    Ownable(msg.sender)
{
    _mint(msg.sender, initialSupply * 10 ** decimals());
}
```

#### `mint`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/MockToken/MockToken.sol#L25-L27)

```solidity
/**
 * Function to mint token
 * @param to Address that receives the minted tokens
 * @param amount Amount to mint
 */
function mint(address to, uint256 amount) external onlyOwner {
    _mint(to, amount);
}
```

#### `burn`
[Check function](https://github.com/LuiscaPP17/YieldFarmingPool/blob/main/src/MockToken/MockToken.sol#L33-L35)

```solidity
/**
 * Function to burn token
 * @param amount Amount to burn
 */
function burn(uint256 amount) external {
    _burn(msg.sender, amount);
}
```

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
