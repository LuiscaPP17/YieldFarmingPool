// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/MockToken/MockToken.sol";

contract MockTokenTest is Test {
    MockToken token;

    address public owner;
    address public user1;

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");

        token = new MockToken("Test Token", "TST", 1000);
    }

    // ---------- constructor ----------

    function test_constructor_SetsNameSymbolOwnerAndInitialSupply() public view {
        assertEq(token.name(), "Test Token", "Token name should be the one passed to the constructor");
        assertEq(token.symbol(), "TST", "Token symbol should be the one passed to the constructor");
        assertEq(uint256(token.decimals()), 18, "Token should use the default 18 decimals");
        assertEq(token.owner(), owner, "Deployer should be the owner");
        assertEq(token.totalSupply(), 1000 * 10 ** 18, "Total supply should be 1000 whole tokens in base units");
        assertEq(token.balanceOf(owner), 1000 * 10 ** 18, "Deployer should receive the whole initial supply");
    }

    // ---------- mint ----------

    function test_mint_OwnerMintsTokensToUser() public {
        token.mint(user1, 500 * 10 ** 18);

        assertEq(token.balanceOf(user1), 500 * 10 ** 18, "user1 should receive the 500 minted tokens");
        assertEq(token.totalSupply(), 1500 * 10 ** 18, "Total supply should grow from 1000 to 1500 after minting 500");
        assertEq(
            token.balanceOf(owner),
            1000 * 10 ** 18,
            "Owner balance should not change because mint creates new tokens instead of moving existing ones"
        );
    }

    function test_mint_RevertsIfCallerIsNotOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        vm.prank(user1);
        token.mint(user1, 500 * 10 ** 18);
    }

    // ---------- burn ----------

    function test_burn_UserBurnsOwnTokens() public {
        token.mint(user1, 500 * 10 ** 18);

        vm.prank(user1);
        token.burn(200 * 10 ** 18);

        assertEq(token.balanceOf(user1), 300 * 10 ** 18, "user1 should keep 300 after burning 200 of the 500 minted");
        assertEq(
            token.totalSupply(),
            1300 * 10 ** 18,
            "Total supply should drop from 1500 to 1300 because burned tokens are destroyed"
        );
        assertEq(
            token.balanceOf(owner),
            1000 * 10 ** 18,
            "Owner balance should not change because burn only affects the caller"
        );
    }
} // forge test -vvvv --match-test
