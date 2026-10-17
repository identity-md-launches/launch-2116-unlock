// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UnlockToken} from "../src/UnlockToken.sol";

/// @dev Test-only bounded actors keep every token balance enumerable during randomized call sequences.
contract TokenHandler is Test {
    UnlockToken public immutable token;
    address[4] public actors;

    constructor(UnlockToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("holder-", vm.toString(i)));
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = unlimited ? type(uint256).max : bound(amount, 0, token.totalSupply());
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 available = token.balanceOf(from);
        uint256 approved = token.allowance(from, spender);
        amount = bound(amount, 0, available < approved ? available : approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(token.allowance(from, spender), approved == type(uint256).max ? approved : approved - amount);
    }
}

contract UnlockTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    UnlockToken internal token;
    TokenHandler internal handler;

    function setUp() public {
        token = new UnlockToken();
        handler = new TokenHandler(token);
        token.transfer(handler.actors(0), SUPPLY);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_allBalancesConserveTheOriginalSupply() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}
