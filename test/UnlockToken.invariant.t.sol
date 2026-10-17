// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {UnlockToken} from "../src/UnlockToken.sol";

/// @dev Test-only bounded actors keep every token balance enumerable during randomized call sequences.
contract TokenHandler is Test {
    UnlockToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    uint256 public nonzeroTransfers;
    uint256 public nonzeroDelegatedTransfers;
    uint256 public rejectedCalls;

    constructor(UnlockToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("holder-", vm.toString(i)));
        }
        // The fixture transfers the constructor's entire supply to actor 0. Never seed or
        // resynchronize this ledger from token getters: that would hide incorrect accounting.
        expectedBalance[actors[0]] = 1_000_000_000 * 10 ** 18;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
        if (amount > 0) ++nonzeroTransfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        // Approvals can exceed supply; include the whole uint256 domain, not just balances.
        _approve(owner, spender, unlimited ? type(uint256).max : amount);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(actors[ownerSeed % actors.length], actors[spenderSeed % actors.length], 0);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 available = expectedBalance[from];
        uint256 approved = expectedAllowance[from][spender];
        amount = bound(amount, 0, available < approved ? available : approved);
        _transferFrom(from, to, spender, amount);
    }

    /// @dev Unlike the valid-action handler, this one accepts the full amount domain. Failed
    /// calls must leave the ledger unchanged, including allowance spent before a balance check.
    function attemptTransferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 approved = expectedAllowance[from][spender];
        uint256 available = expectedBalance[from];
        if (approved != type(uint256).max && amount > approved) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
            );
        } else if (amount > available) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, available, amount)
            );
        } else {
            _transferFrom(from, to, spender, amount);
            return;
        }
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        ++rejectedCalls;
    }

    function overdraw(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 available = expectedBalance[from];
        amount = bound(amount, available + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, available, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ++rejectedCalls;
    }

    /// @dev Exercise invalid receivers/spenders amid existing approvals and transfers.
    /// For transferFrom, give it sufficient existing allowance so the zero receiver is reached.
    function rejectZeroAddress(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint8 operation) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        if (operation % 3 == 0) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(owner);
            token.transfer(address(0), amount);
        } else if (operation % 3 == 1) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            vm.prank(owner);
            token.approve(address(0), amount);
        } else {
            amount = bound(amount, 0, expectedAllowance[owner][spender]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(owner, address(0), amount);
        }
        ++rejectedCalls;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _transferFrom(address from, address to, address spender, uint256 amount) internal {
        uint256 approved = expectedAllowance[from][spender];
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        if (approved != type(uint256).max) expectedAllowance[from][spender] -= amount;
        _recordTransfer(from, to, amount);
        if (amount > 0) ++nonzeroDelegatedTransfers;
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        // An aliased sender/receiver is a net-zero movement, but still spends delegated allowance.
        if (from == to) return;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract UnlockTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    UnlockToken internal token;
    TokenHandler internal handler;

    function setUp() public {
        token = new UnlockToken();
        handler = new TokenHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        selectors[3] = TokenHandler.revoke.selector;
        selectors[4] = TokenHandler.attemptTransferFrom.selector;
        selectors[5] = TokenHandler.overdraw.selector;
        selectors[6] = TokenHandler.rejectZeroAddress.selector;
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

    /// @dev Conservation alone would miss sending the right amount to the wrong account.
    function invariant_balancesMatchAuthorizedMovements() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "unauthorized balance change");
        }
    }

    /// @dev Check every pair, including untouched pairs and self-approval, after every action.
    function invariant_allowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            assertEq(token.allowance(address(0), owner), 0);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "approval changed without authorization or a successful spend"
                );
            }
        }
    }

    /// @dev Deterministic reachability check: neither the successful-spend paths nor the rollback
    /// paths depend on the random runner happening to construct a useful approval/balance state.
    function test_handlerExercisesSpendingRevocationAndRollback() public {
        handler.transfer(0, 1, 100);
        handler.approve(1, 2, 60, false);
        handler.transferFrom(1, 3, 2, 40);
        handler.transferFrom(1, 1, 2, 20); // self-transfer still exhausts the allowance
        handler.attemptTransferFrom(1, 3, 2, 1); // exhausted approval
        _assertAllInvariants();

        handler.approve(1, 2, 61, false);
        handler.attemptTransferFrom(1, 3, 2, 61); // balance is only 60; allowance must roll back
        handler.rejectZeroAddress(1, 2, 60, 2);
        _assertAllInvariants();
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), 61);

        handler.approve(1, 2, 0, true);
        handler.transferFrom(1, 3, 2, 60);
        handler.attemptTransferFrom(1, 3, 2, 1); // infinite approval does not bypass balance checks
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), type(uint256).max);
        _assertAllInvariants();

        handler.transfer(3, 1, 10);
        handler.revoke(1, 2);
        handler.attemptTransferFrom(1, 3, 2, 1); // revocation remains effective after funding
        handler.overdraw(1, 1, 11); // self-transfer must still check the available balance
        handler.rejectZeroAddress(1, 2, 0, 0);
        handler.rejectZeroAddress(1, 2, type(uint256).max, 1);
        _assertAllInvariants();

        assertEq(handler.nonzeroTransfers(), 2);
        assertEq(handler.nonzeroDelegatedTransfers(), 3);
        assertEq(handler.rejectedCalls(), 8);
    }

    function _assertAllInvariants() internal view {
        invariant_totalSupplyIsFixed();
        invariant_allBalancesConserveTheOriginalSupply();
        invariant_balancesMatchAuthorizedMovements();
        invariant_allowancesMatchApprovalsAndSuccessfulSpending();
    }
}
