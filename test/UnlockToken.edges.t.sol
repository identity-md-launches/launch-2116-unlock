// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {UnlockToken} from "src/UnlockToken.sol";

/// @notice Boundary and sequence properties supplement the original deployment/ERC-20 tests.
/// forge-config: default.fuzz.runs = 1000
contract UnlockTokenEdgeCasesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    UnlockToken internal token;
    address internal holder;
    address internal recipient;
    address internal spender;
    address internal otherSpender;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new UnlockToken();
        holder = makeAddr("edge holder");
        recipient = makeAddr("edge recipient");
        spender = makeAddr("edge spender");
        otherSpender = makeAddr("edge other spender");
    }

    function test_oneBaseUnitCanMakeARoundTrip() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), holder, 1);
        assertTrue(token.transfer(holder, 1));
        assertEq(token.balanceOf(holder), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);

        vm.prank(holder);
        assertTrue(token.transfer(recipient, 1));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 1);
        vm.prank(recipient);
        assertTrue(token.transfer(address(this), 1));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        _assertConserved();
    }

    function test_emptySelfTransferCannotCreateTokens() public {
        vm.prank(holder);
        assertTrue(token.transfer(holder, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        vm.prank(holder);
        token.transfer(holder, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, type(uint256).max)
        );
        vm.prank(holder);
        token.transfer(holder, type(uint256).max);
        assertEq(token.balanceOf(holder), 0);
        _assertConserved();
    }

    function test_maxUintTransferCannotWrapTheDeployerBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(holder, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(holder), 0);
        _assertConserved();
    }

    function test_ownerNeedsSelfApprovalToUseTransferFrom() public {
        assertTrue(token.transfer(holder, 10));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder, 0, 10));
        vm.prank(holder);
        token.transferFrom(holder, recipient, 10);
        assertEq(token.balanceOf(holder), 10);
        assertEq(token.balanceOf(recipient), 0);

        vm.startPrank(holder);
        assertTrue(token.approve(holder, 10));
        assertTrue(token.transferFrom(holder, recipient, 10));
        vm.stopPrank();
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 10);
        assertEq(token.allowance(holder, holder), 0);
        _assertConserved();
    }

    function test_maxUintMinusOneIsAFiniteAllowance() public {
        uint256 approved = type(uint256).max - 1;
        assertTrue(token.approve(spender, approved));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, SUPPLY));
        assertEq(token.allowance(address(this), spender), approved - SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(recipient), SUPPLY);
        _assertConserved();
    }

    function test_entireSupplyCanBeSpentWithAnExactFiniteAllowanceOnlyOnce() public {
        assertTrue(token.approve(spender, SUPPLY));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, SUPPLY));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(recipient), SUPPLY);

        // Returning funds must not restore a consumed authorization.
        vm.prank(recipient);
        assertTrue(token.transfer(address(this), SUPPLY));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(address(this), spender), 0);
        _assertConserved();
    }

    function test_infiniteAllowanceCannotOverdrawAndCanBeRevoked() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(spender);
        token.transferFrom(address(this), recipient, SUPPLY + 1);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);

        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        _assertConserved();
    }

    function test_infiniteApprovalCanBeReplacedWithAFiniteOne() public {
        assertTrue(token.approve(spender, type(uint256).max));
        assertTrue(token.approve(otherSpender, 7));
        assertTrue(token.approve(spender, 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.allowance(address(this), otherSpender), 7);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        _assertConserved();
    }

    function test_zeroDelegatedTransferEmitsAndPreservesFiniteAllowance() public {
        // The holder is empty but may still grant an allowance and send zero tokens.
        vm.prank(holder);
        assertTrue(token.approve(spender, 1));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 0);
        _assertConserved();
    }

    function test_zeroSpenderIsRejectedForZeroAndMaxApproval() public {
        assertTrue(token.approve(spender, 7));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.allowance(address(this), spender), 7);
        _assertConserved();
    }

    function test_zeroDelegatedTransferToZeroRevertsForFiniteAndInfiniteAllowances() public {
        uint256[2] memory approvals = [uint256(7), type(uint256).max];
        for (uint256 i; i < approvals.length; ++i) {
            assertTrue(token.approve(spender, approvals[i]));
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(address(this), address(0), 0);
            assertEq(token.allowance(address(this), spender), approvals[i]);
        }
        assertEq(token.balanceOf(address(this)), SUPPLY);
        _assertConserved();
    }

    function test_nativeValueIsRejectedWithoutMovingTokens() public {
        vm.deal(address(this), 2);
        (bool emptyCallSucceeded,) = address(token).call{value: 1}("");
        assertFalse(emptyCallSucceeded);
        (bool transferSucceeded,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (holder, 1)));
        assertFalse(transferSucceeded);
        assertEq(address(this).balance, 2);
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(holder), 0);
        _assertConserved();
    }

    function testFuzz_roundTripRestoresAllBalances(uint256 amount, uint256 onward) public {
        amount = bound(amount, 0, SUPPLY);
        onward = bound(onward, 0, amount);
        assertTrue(token.transfer(holder, amount));
        vm.prank(holder);
        assertTrue(token.transfer(recipient, onward));
        vm.prank(holder);
        assertTrue(token.transfer(address(this), amount - onward));
        vm.prank(recipient);
        assertTrue(token.transfer(address(this), onward));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 0);
        _assertConserved();
    }

    function testFuzz_approvalReplacementIsIdempotentAndIsolated(uint256 first, uint256 replacement, uint256 other)
        public
    {
        assertTrue(token.approve(otherSpender, other));
        vm.prank(holder);
        assertTrue(token.approve(spender, other));
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(address(this), spender), first);
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(address(this), spender), replacement);
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(address(this), spender), replacement);
        assertEq(token.allowance(address(this), otherSpender), other);
        assertEq(token.allowance(holder, spender), other);
        assertEq(token.allowance(spender, address(this)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        _assertConserved();
    }

    function testFuzz_delegatedSelfTransferOnlySpendsAllowance(uint256 balance, uint256 amount, uint256 approved)
        public
    {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, 0, balance);
        approved = bound(approved, amount, type(uint256).max);
        assertTrue(token.transfer(holder, balance));
        vm.prank(holder);
        assertTrue(token.approve(spender, approved));
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, holder, amount));
        assertEq(token.balanceOf(holder), balance);
        assertEq(token.balanceOf(address(this)), SUPPLY - balance);
        assertEq(token.allowance(holder, spender), approved == type(uint256).max ? approved : approved - amount);
        _assertConserved();
    }

    function testFuzz_failedDelegatedOverdrawPreservesApproval(
        uint256 balance,
        uint256 amount,
        bool unlimited,
        bool selfTransfer
    ) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        uint256 approved = unlimited ? type(uint256).max : amount;
        assertTrue(token.transfer(holder, balance));
        vm.prank(holder);
        assertTrue(token.approve(spender, approved));
        vm.prank(holder);
        assertTrue(token.approve(otherSpender, 17));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, amount));
        vm.prank(spender);
        token.transferFrom(holder, selfTransfer ? holder : recipient, amount);
        assertEq(token.allowance(holder, spender), approved);
        assertEq(token.allowance(holder, otherSpender), 17);
        assertEq(token.balanceOf(holder), balance);
        assertEq(token.balanceOf(address(this)), SUPPLY - balance);
        assertEq(token.balanceOf(recipient), 0);
        _assertConserved();
    }

    /// @dev Metamorphic property: splitting an authorized spend cannot change its net effects.
    function testFuzz_splitDelegatedSpendEqualsSingleSpend(uint256 total, uint256 first, uint256 approved) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        approved = bound(approved, total, type(uint256).max);
        UnlockToken single = new UnlockToken();
        assertTrue(token.approve(spender, approved));
        assertTrue(single.approve(spender, approved));
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), recipient, first));
        assertTrue(token.transferFrom(address(this), recipient, total - first));
        assertTrue(single.transferFrom(address(this), recipient, total));
        vm.stopPrank();

        assertEq(token.balanceOf(recipient), total);
        assertEq(single.balanceOf(recipient), token.balanceOf(recipient));
        assertEq(single.balanceOf(address(this)), token.balanceOf(address(this)));
        assertEq(single.allowance(address(this), spender), token.allowance(address(this), spender));
        assertEq(token.allowance(address(this), spender), approved == type(uint256).max ? approved : approved - total);
        assertEq(single.totalSupply(), SUPPLY);
        _assertConserved();
    }

    function testFuzz_failedZeroRecipientSpendCanBeRetriedWithValidRecipient(uint256 amount, bool unlimited) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 approved = unlimited ? type(uint256).max : amount;
        assertTrue(token.approve(spender, approved));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        _assertConserved();

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.allowance(address(this), spender), unlimited ? type(uint256).max : 0);
        _assertConserved();
    }

    function _assertConserved() internal view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(holder) + token.balanceOf(recipient)
                + token.balanceOf(spender) + token.balanceOf(otherSpender),
            SUPPLY
        );
    }
}
