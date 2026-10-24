// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "../src/MockToken/MockToken.sol";
import "../src/YieldFarmingPool.sol";
import "../lib/forge-std/src/Test.sol";

contract YieldFarmingPoolTest is Test {
    YieldFarmingPool public yieldFarmingPool;
    MockToken public rewardToken;
    MockToken public stakingToken1;
    MockToken public stakingToken2;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    bytes32 public poolId1;
    bytes32 public poolId2;

    uint256 public constant INITIAL_SUPPLY = 1000000 * 10 ** 18;
    uint256 public constant REWARD_RATE = 1 * 10 ** 16; // 0.01 tokens por segundo

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy tokens
        rewardToken = new MockToken("Reward Token", "RWD", INITIAL_SUPPLY);
        stakingToken1 = new MockToken("Staking Token 1", "STK1", INITIAL_SUPPLY);
        stakingToken2 = new MockToken("Staking Token 2", "STK2", INITIAL_SUPPLY);

        // Deploy contracts
        yieldFarmingPool = new YieldFarmingPool(address(rewardToken));

        // Transfer tokens to users
        stakingToken1.transfer(user1, 10000 * 10 ** 18);
        stakingToken1.transfer(user2, 10000 * 10 ** 18);
        stakingToken2.transfer(user1, 10000 * 10 ** 18);
        stakingToken2.transfer(user3, 10000 * 10 ** 18);

        // Transfer reward tokens to the farming pool
        rewardToken.transfer(address(yieldFarmingPool), 500000 * 10 ** 18);

        // Create pools
        poolId1 = yieldFarmingPool.createPool(address(stakingToken1), REWARD_RATE);
        poolId2 = yieldFarmingPool.createPool(address(stakingToken2), REWARD_RATE * 2);

        // Approve tokens
        vm.startPrank(user1);
        stakingToken1.approve(address(yieldFarmingPool), type(uint256).max);
        stakingToken2.approve(address(yieldFarmingPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        stakingToken1.approve(address(yieldFarmingPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user3);
        stakingToken2.approve(address(yieldFarmingPool), type(uint256).max);
        vm.stopPrank();
    }

    // ---------- constructor ----------

    function test_constructor_SetsRewardTokenAndOwner() public view {
        assertEq(address(yieldFarmingPool.rewardToken()), address(rewardToken));
        assertEq(yieldFarmingPool.owner(), owner);
    }

    function test_constructor_RevertsWithZeroAddress() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Invalid reward token"));
        new YieldFarmingPool(address(0));
    }

    // ---------- createPool ----------

    function test_createPool_CreatesPoolWithCorrectData() public {
        uint256 newRate = 5 * 10 ** 15;
        vm.warp(1000);

        bytes32 expectedId =
            keccak256(abi.encodePacked(address(stakingToken1), newRate, block.timestamp, block.chainid));

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.PoolCreated(expectedId, address(stakingToken1), newRate);

        bytes32 returnedId = yieldFarmingPool.createPool(address(stakingToken1), newRate);

        assertEq(returnedId, expectedId, "createPool should return the keccak256 of token, rate, timestamp and chainid");

        (
            address token,
            uint256 totalStaked,
            uint256 rewardRate,
            uint256 lastUpdateTime,
            uint256 rewardPerTokenStored,
            bool isActive
        ) = yieldFarmingPool.pools(returnedId);

        assertEq(token, address(stakingToken1), "Pool should store the staking token address");
        assertEq(totalStaked, 0, "New pool should start with nothing staked");
        assertEq(rewardRate, newRate, "Pool should store the reward rate passed to createPool");
        assertEq(lastUpdateTime, 1000, "lastUpdateTime should be the creation timestamp");
        assertEq(rewardPerTokenStored, 0, "New pool should start with zero accumulated rewards per token");
        assertTrue(isActive, "New pool should be active");
        assertEq(yieldFarmingPool.getActivePoolsCount(), 3, "Active pools should be 3: two from setUp plus the new one");
    }

    function test_createPool_RevertsIfCallerIsNotOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        vm.prank(user1);
        yieldFarmingPool.createPool(address(stakingToken1), 1 ether);
    }

    function test_createPool_RevertsWithZeroTokenAddress() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Invalid token address"));
        yieldFarmingPool.createPool(address(0), 1 ether);
    }

    function test_createPool_RevertsWithZeroRewardRate() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Reward rate must be positive"));
        yieldFarmingPool.createPool(address(stakingToken1), 0);
    }

    function test_createPool_RevertsIfPoolAlreadyExists() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Pool already exists"));
        yieldFarmingPool.createPool(address(stakingToken1), REWARD_RATE);
    }

    // ---------- stake ----------

    function test_stake_FirstDepositUpdatesBalancesAndState() public {
        uint256 amount = 1000 * 10 ** 18;
        vm.warp(500);

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.Staked(poolId1, user1, amount);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, amount);

        assertEq(stakingToken1.balanceOf(user1), 9000 * 10 ** 18, "user1 should have 10000 minus the 1000 staked");
        assertEq(
            stakingToken1.balanceOf(address(yieldFarmingPool)),
            1000 * 10 ** 18,
            "Pool should hold exactly the 1000 tokens user1 staked"
        );

        (uint256 userAmount, uint256 rewardDebt, uint256 lastClaimTime) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(userAmount, amount, "Pool should record user1's staked amount");
        assertEq(rewardDebt, 0, "First deposit should start with zero reward debt");
        assertEq(lastClaimTime, 500, "lastClaimTime should be the deposit timestamp");

        (, uint256 totalStaked,, uint256 lastUpdateTime, uint256 rewardPerTokenStored,) =
            yieldFarmingPool.pools(poolId1);

        assertEq(totalStaked, amount, "Pool total staked should equal the amount user1 deposited");
        assertEq(lastUpdateTime, 500, "Pool lastUpdateTime should move to the deposit timestamp");
        assertEq(rewardPerTokenStored, 0, "No rewards accrue when the pool had nothing staked before");
    }

    function test_stake_RevertsIfPoolIsNotActive() public {
        bytes32 fakePoolId = keccak256("fake pool");

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Pool is not active"));
        vm.prank(user1);
        yieldFarmingPool.stake(fakePoolId, 1 ether);
    }

    function test_stake_RevertsWithZeroAmount() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Amount must be positive"));
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 0);
    }

    function test_stake_SecondDepositPaysPendingRewards() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.warp(1100);

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.RewardClaimed(poolId1, user1, 1 * 10 ** 18);
        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.Staked(poolId1, user1, 500 * 10 ** 18);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 500 * 10 ** 18);

        assertEq(
            rewardToken.balanceOf(user1),
            1 * 10 ** 18,
            "user1 should be paid 1 reward token for 100 seconds at 0.01 per second"
        );
        assertEq(
            rewardToken.balanceOf(address(yieldFarmingPool)),
            500000 * 10 ** 18 - 1 * 10 ** 18,
            "Pool reward balance should drop by the 1 token paid out"
        );

        (uint256 userAmount, uint256 rewardDebt, uint256 lastClaimTime) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(userAmount, 1500 * 10 ** 18, "user1 staked amount should be 1000 plus 500");
        assertEq(rewardDebt, 15 * 10 ** 17, "rewardDebt should be 1500 tokens times 0.001 reward per token");
        assertEq(lastClaimTime, 1100, "lastClaimTime should be the second deposit timestamp");

        (, uint256 totalStaked,,, uint256 rewardPerTokenStored,) = yieldFarmingPool.pools(poolId1);

        assertEq(totalStaked, 1500 * 10 ** 18, "Pool total staked should be 1500 after the second deposit");
        assertEq(rewardPerTokenStored, 1 * 10 ** 15, "1 reward token over 1000 staked is 0.001 per token");
    }

    function test_stake_SecondDepositInSameSecondPaysNothing() public {
        vm.warp(1000);

        vm.startPrank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);
        yieldFarmingPool.stake(poolId1, 500 * 10 ** 18);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user1), 0, "No time passed, so user1 should receive no rewards");

        (uint256 userAmount, uint256 rewardDebt,) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(userAmount, 1500 * 10 ** 18, "user1 staked amount should be 1000 plus 500");
        assertEq(rewardDebt, 0, "rewardDebt should stay zero because rewardPerTokenStored never moved");
    }

    // ---------- withdraw ----------

    function test_withdraw_PartialWithdrawPaysRewardsAndReturnsTokens() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.warp(1100);

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.RewardClaimed(poolId1, user1, 1 * 10 ** 18);
        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.Withdrawn(poolId1, user1, 400 * 10 ** 18);

        vm.prank(user1);
        yieldFarmingPool.withdraw(poolId1, 400 * 10 ** 18);

        assertEq(
            rewardToken.balanceOf(user1),
            1 * 10 ** 18,
            "user1 should be paid 1 reward token for 100 seconds at 0.01 per second"
        );
        assertEq(
            stakingToken1.balanceOf(user1),
            9400 * 10 ** 18,
            "user1 should have 10000 minus 1000 staked plus 400 withdrawn"
        );
        assertEq(
            stakingToken1.balanceOf(address(yieldFarmingPool)),
            600 * 10 ** 18,
            "Pool should keep the 600 tokens not withdrawn"
        );

        (uint256 userAmount, uint256 rewardDebt, uint256 lastClaimTime) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(userAmount, 600 * 10 ** 18, "user1 staked amount should be 600");
        assertEq(rewardDebt, 6 * 10 ** 17, "rewardDebt should be 600 tokens times 0.001 reward per token");
        assertEq(lastClaimTime, 1000, "withdraw should not update lastClaimTime, it stays at the stake timestamp");

        (, uint256 totalStaked,,, uint256 rewardPerTokenStored,) = yieldFarmingPool.pools(poolId1);

        assertEq(totalStaked, 600 * 10 ** 18, "Pool total staked should drop to 600 after the withdrawal");
        assertEq(rewardPerTokenStored, 1 * 10 ** 15, "1 reward token over 1000 staked is 0.001 per token");
    }

    function test_withdraw_RevertsIfAmountExceedsStaked() public {
        vm.startPrank(user1);
        yieldFarmingPool.stake(poolId1, 400 * 10 ** 18);

        vm.expectRevert("Insufficient staked amount");
        yieldFarmingPool.withdraw(poolId1, 401 * 10 ** 18);

        vm.stopPrank();
    }

    function test_withdraw_FullWithdrawWithoutPendingRewards() public {
        vm.warp(1000);

        vm.startPrank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);
        yieldFarmingPool.withdraw(poolId1, 1000 * 10 ** 18);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(user1), 0, "No time passed between stake and withdraw, so no rewards accrued");
        assertEq(
            stakingToken1.balanceOf(user1),
            10000 * 10 ** 18,
            "user1 should get back every token after a full withdrawal"
        );
        assertEq(
            stakingToken1.balanceOf(address(yieldFarmingPool)),
            0,
            "Pool should hold no staking tokens after the only staker leaves"
        );

        (uint256 userAmount, uint256 rewardDebt,) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(userAmount, 0, "user1 staked amount should be zero after a full withdrawal");
        assertEq(rewardDebt, 0, "rewardDebt should be zero because rewardPerTokenStored never moved");

        (, uint256 totalStaked,,,,) = yieldFarmingPool.pools(poolId1);
        assertEq(totalStaked, 0, "Pool total staked should return to zero");
    }

    // ---------- claimRewards ----------

    function test_claimRewards_PaysPendingRewardsAndKeepsStake() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.warp(1100);

        vm.expectEmit(true, true, false, true);
        emit YieldFarmingPool.RewardClaimed(poolId1, user1, 1 * 10 ** 18);

        vm.prank(user1);
        yieldFarmingPool.claimRewards(poolId1);

        assertEq(
            rewardToken.balanceOf(user1),
            1 * 10 ** 18,
            "user1 should be paid 1 reward token for 100 seconds at 0.01 per second"
        );
        assertEq(
            rewardToken.balanceOf(address(yieldFarmingPool)),
            500000 * 10 ** 18 - 1 * 10 ** 18,
            "Pool reward balance should drop by the 1 token paid out"
        );

        (uint256 userAmount, uint256 rewardDebt, uint256 lastClaimTime) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(userAmount, 1000 * 10 ** 18, "Claiming rewards should not touch the staked amount");
        assertEq(rewardDebt, 1 * 10 ** 18, "rewardDebt should be 1000 tokens times 0.001 reward per token");
        assertEq(lastClaimTime, 1100, "claimRewards should update lastClaimTime to the claim timestamp");

        (, uint256 totalStaked,,, uint256 rewardPerTokenStored,) = yieldFarmingPool.pools(poolId1);

        assertEq(totalStaked, 1000 * 10 ** 18, "Pool total staked should not change when only rewards are claimed");
        assertEq(rewardPerTokenStored, 1 * 10 ** 15, "1 reward token over 1000 staked is 0.001 per token");
    }

    function test_claimRewards_RevertsIfNoRewardsToClaim() public {
        vm.expectRevert("No rewards to claim");
        vm.prank(user1);
        yieldFarmingPool.claimRewards(poolId1);
    }

    function test_claimRewards_PaysOnlyWhatPoolHasWhenRewardBalanceIsLow() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.warp(1100);

        yieldFarmingPool.emergencyWithdraw(address(rewardToken), 500000 * 10 ** 18 - 4 * 10 ** 17);

        vm.prank(user1);
        yieldFarmingPool.claimRewards(poolId1);

        assertEq(
            rewardToken.balanceOf(user1),
            4 * 10 ** 17,
            "user1 should receive only the 0.4 tokens left in the pool, not the full 1 token owed"
        );
        assertEq(rewardToken.balanceOf(address(yieldFarmingPool)), 0, "Pool reward balance should be fully drained");

        (uint256 userAmount, uint256 rewardDebt,) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(userAmount, 1000 * 10 ** 18, "Claiming rewards should not touch the staked amount");
        assertEq(
            rewardDebt,
            1 * 10 ** 18,
            "rewardDebt is computed from the full accrual (1000 x 0.001), so the unpaid 0.6 is lost"
        );
    }

    function test_claimRewards_PaysNothingWhenRewardBalanceIsEmpty() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.warp(1100);

        yieldFarmingPool.emergencyWithdraw(address(rewardToken), 500000 * 10 ** 18);
        vm.prank(user1);
        yieldFarmingPool.claimRewards(poolId1);

        assertEq(rewardToken.balanceOf(user1), 0, "user1 should receive nothing because the reward balance is empty");
        assertEq(rewardToken.balanceOf(address(yieldFarmingPool)), 0, "Pool reward balance should stay at zero");

        (, uint256 rewardDebt, uint256 lastClaimTime) = yieldFarmingPool.userInfo(poolId1, user1);

        assertEq(rewardDebt, 1 * 10 ** 18, "rewardDebt still records the full accrual even though nothing was paid");
        assertEq(lastClaimTime, 1100, "claimRewards should update lastClaimTime to the claim timestamp");
    }

    // ---------- updatePoolRewardRate ----------

    function test_updatePoolRewardRate_SettlesOldRateAndStoresNewOne() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.warp(1100);
        uint256 newRate = REWARD_RATE * 2;

        vm.expectEmit(true, false, false, true);
        emit YieldFarmingPool.PoolUpdated(poolId1, newRate);

        yieldFarmingPool.updatePoolRewardRate(poolId1, newRate);

        (, uint256 totalStaked, uint256 rewardRate, uint256 lastUpdateTime, uint256 rewardPerTokenStored,) =
            yieldFarmingPool.pools(poolId1);

        assertEq(rewardRate, 2 * 10 ** 16, "Pool should store the new reward rate, double the original");
        assertEq(
            rewardPerTokenStored,
            1 * 10 ** 15,
            "The 100 seconds before the change settle at the OLD rate: 1 token over 1000 staked is 0.001 per token"
        );
        assertEq(lastUpdateTime, 1100, "lastUpdateTime should move to the moment of the rate change");
        assertEq(totalStaked, 1000 * 10 ** 18, "Changing the rate should not touch the staked amount");
    }

    function test_updatePoolRewardRate_RevertsIfCallerIsNotOwner() public {
        uint256 newRate = REWARD_RATE * 2;

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        vm.prank(user1);
        yieldFarmingPool.updatePoolRewardRate(poolId1, newRate);
    }

    function test_updatePoolRewardRate_RevertsIfPoolIsNotActive() public {
        bytes32 fakePoolId = keccak256("fake pool");
        uint256 newRate = REWARD_RATE * 2;

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Pool is not active"));
        yieldFarmingPool.updatePoolRewardRate(fakePoolId, newRate);
    }

    // ---------- pendingRewards ----------

    function test_pendingRewards_ReturnsAccruedRewardsWithoutChangingState() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.warp(1100);

        uint256 pending = yieldFarmingPool.pendingRewards(poolId1, user1);

        assertEq(pending, 1 * 10 ** 18, "user1 should have 1 reward token pending after 100 seconds at 0.01 per second");

        (,,, uint256 lastUpdateTime, uint256 rewardPerTokenStored,) = yieldFarmingPool.pools(poolId1);

        assertEq(rewardPerTokenStored, 0, "A view call must not settle rewards, so rewardPerTokenStored stays at zero");
        assertEq(lastUpdateTime, 1000, "A view call must not move the pool clock, it stays at the stake timestamp");
    }

    function test_pendingRewards_ReturnsZeroWhenPoolIsEmpty() public {
        vm.warp(1100);

        uint256 pending = yieldFarmingPool.pendingRewards(poolId1, user1);

        assertEq(pending, 0, "An empty pool has no stakers to reward, so nothing accrues even as time passes");
    }

    function test_pendingRewards_SplitsRewardsProportionallyBetweenUsers() public {
        vm.warp(1000);

        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        vm.prank(user2);
        yieldFarmingPool.stake(poolId1, 3000 * 10 ** 18);

        vm.warp(1100);

        uint256 pending1 = yieldFarmingPool.pendingRewards(poolId1, user1);
        uint256 pending2 = yieldFarmingPool.pendingRewards(poolId1, user2);

        assertEq(pending1, 25 * 10 ** 16, "user1 staked 1000 of 4000, so should get a quarter of the 1 token reward");
        assertEq(
            pending2, 75 * 10 ** 16, "user2 staked 3000 of 4000, so should get three quarters of the 1 token reward"
        );
        assertEq(
            pending1 + pending2,
            1 * 10 ** 18,
            "Both shares together should equal the total reward accrued, nothing created or lost"
        );
    }

    // ---------- getPoolEncodedData ----------

    function test_getPoolEncodedData_ReturnsPackedPoolData() public {
        vm.warp(1000);
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        bytes memory data = yieldFarmingPool.getPoolEncodedData(poolId1);

        assertEq(data.length, 149, "Packed pool data should be 149 bytes: 20 (address) + 4 x 32 (uint256) + 1 (bool)");

        bytes memory expected = abi.encodePacked(
            address(stakingToken1), uint256(1000 * 10 ** 18), REWARD_RATE, uint256(1000), uint256(0), true
        );

        assertEq(
            data,
            expected,
            "Packed pool data should match token, totalStaked, rewardRate, lastUpdateTime, rewardPerTokenStored and isActive in order"
        );
    }

    // ---------- getUserHash ----------

    function test_getUserHash_ReturnsExpectedHashAndDiffersPerUser() public view {
        bytes32 hash1 = yieldFarmingPool.getUserHash(poolId1, user1);
        bytes32 hash2 = yieldFarmingPool.getUserHash(poolId1, user2);

        bytes32 expected1 = keccak256(abi.encodePacked(poolId1, user1, "YIELD_FARMING_USER"));

        assertEq(
            hash1, expected1, "User hash should be keccak256 of poolId, user address and the YIELD_FARMING_USER tag"
        );
        assertNotEq(
            hash1,
            hash2,
            "Two different users in the same pool must have different hashes, or their positions would be mixed up"
        );
    }

    // ---------- getActivePoolsCount ----------

    function test_getActivePoolsCount_ReturnsPoolsCreatedInSetUp() public view {
        assertEq(yieldFarmingPool.getActivePoolsCount(), 2, "Active pools should be 2: the two pools created in setUp");
    }

    // ---------- getActivePools ----------

    function test_getActivePools_ReturnsPoolIdsInCreationOrder() public view {
        bytes32[] memory activePools = yieldFarmingPool.getActivePools();

        assertEq(activePools.length, 2, "Active pools list should hold the two pools created in setUp");
        assertEq(activePools[0], poolId1, "First entry should be poolId1, the first pool created");
        assertEq(activePools[1], poolId2, "Second entry should be poolId2, the second pool created");
    }

    // ---------- emergencyWithdraw ----------

    function test_emergencyWithdraw_OwnerWithdrawsTokensFromPool() public {
        vm.prank(user1);
        yieldFarmingPool.stake(poolId1, 1000 * 10 ** 18);

        uint256 ownerBefore = stakingToken1.balanceOf(owner);

        yieldFarmingPool.emergencyWithdraw(address(stakingToken1), 400 * 10 ** 18);

        assertEq(
            stakingToken1.balanceOf(owner) - ownerBefore,
            400 * 10 ** 18,
            "Owner should receive exactly the 400 tokens withdrawn"
        );
        assertEq(
            stakingToken1.balanceOf(address(yieldFarmingPool)),
            600 * 10 ** 18,
            "Pool should keep 600: the 1000 staked minus the 400 withdrawn"
        );
    }

    function test_emergencyWithdraw_RevertsIfCallerIsNotOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        vm.prank(user1);
        yieldFarmingPool.emergencyWithdraw(address(stakingToken1), 400 * 10 ** 18);
    }
} // forge test -vvvv --match-test
