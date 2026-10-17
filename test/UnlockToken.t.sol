// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {UnlockToken} from "../src/UnlockToken.sol";

/// @dev Test-only factory to exercise CREATE2 deployment and launch distribution.
contract TokenDeployer {
    function deploy(bytes32 salt) external returns (UnlockToken) {
        return new UnlockToken{salt: salt}();
    }

    function distribute(UnlockToken token, address distributor, address poolManager, address remainder) external {
        uint256 supply = token.totalSupply();
        require(token.transfer(distributor, supply / 10));
        require(token.transfer(poolManager, supply * 8 / 10));
        require(token.transfer(remainder, supply / 10));
    }
}

contract UnlockTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    UnlockToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new UnlockToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    function test_metadataAndInitialSupply() public view {
        assertEq(token.name(), "UNLOCK");
        assertEq(token.symbol(), "UNLK");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        UnlockToken deployed = new UnlockToken();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].emitter, address(deployed));
        assertEq(entries[0].topics.length, 3);
        assertEq(entries[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(entries[0].topics[1], bytes32(0));
        assertEq(entries[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(entries[0].data, (uint256)), SUPPLY);
    }

    function test_create2MintsToFactoryAndNotOrigin() public {
        TokenDeployer factory = new TokenDeployer();
        bytes32 salt = keccak256("UNLK test deployment");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(factory), salt, keccak256(type(UnlockToken).creationCode)
                        )
                    )
                )
            )
        );

        vm.prank(alice, alice);
        UnlockToken deployed = factory.deploy(salt);
        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(alice), 0);
        assertEq(deployed.balanceOf(address(this)), 0);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_factoryDistributionAndClaimArriveWhole() public {
        TokenDeployer factory = new TokenDeployer();
        UnlockToken deployed = factory.deploy(bytes32(uint256(1)));
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("pool manager");
        factory.distribute(deployed, distributor, poolManager, alice);

        assertEq(deployed.balanceOf(address(factory)), 0);
        assertEq(deployed.balanceOf(distributor), SUPPLY / 10);
        assertEq(deployed.balanceOf(poolManager), SUPPLY * 8 / 10);
        assertEq(deployed.balanceOf(alice), SUPPLY / 10);

        vm.prank(distributor);
        assertTrue(deployed.transfer(bob, SUPPLY / 10));
        assertEq(deployed.balanceOf(distributor), 0);
        assertEq(deployed.balanceOf(bob), SUPPLY / 10);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_transferMovesExactAmountAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 123 ether);
        assertTrue(token.transfer(alice, 123 ether));
        assertEq(token.balanceOf(alice), 123 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferEntireBalance() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToContractNeedsNoReceiverHook() public {
        TokenDeployer receiver = new TokenDeployer();
        assertTrue(token.transfer(address(receiver), 1 ether));
        assertEq(token.balanceOf(address(receiver)), 1 ether);
    }

    function test_transferAboveBalanceRevertsWithoutChangingBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveEmitsEventWithoutMovingTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 50 ether);
        assertTrue(token.approve(spender, 50 ether));
        assertEq(token.allowance(address(this), spender), 50 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_approvalCanBeReplacedAndRevoked() public {
        token.approve(spender, 50 ether);
        token.approve(spender, 10 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        token.approve(spender, 0);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), alice, 1);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_transferFromSpendsFiniteAllowanceAndEmitsTransfer() public {
        token.approve(spender, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 40 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 40 ether));
        assertEq(token.allowance(address(this), spender), 60 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 40 ether);
        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.balanceOf(spender), 0);

        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 60 ether));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromInfiniteAllowanceRemainsInfinite() public {
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 10 ether));
        assertTrue(token.transferFrom(address(this), bob, 20 ether));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 30 ether);
    }

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromSelfStillSpendsAllowance() public {
        token.approve(spender, 1 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 1 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_transferFromWithoutAllowanceRevertsEvenForDeployer() public {
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromAboveAllowanceRevertsAtomically() public {
        token.approve(spender, 10 ether);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10 ether, 11 ether)
        );
        token.transferFrom(address(this), alice, 11 ether);
        assertEq(token.allowance(address(this), spender), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferFromAboveBalanceRestoresAllowance() public {
        token.approve(spender, SUPPLY + 1);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transferFrom(address(this), alice, SUPPLY + 1);
        assertEq(token.allowance(address(this), spender), SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_transferFromToZeroRestoresAllowance() public {
        token.approve(spender, 1 ether);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 1 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroSenderReverts() public {
        // The allowance update validates the owner before the transfer validates its sender.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_adminMintAndBurnEntryPointsAreUnavailable() public {
        token.transfer(alice, 100 ether);
        bytes[] memory attempts = new bytes[](12);
        attempts[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1 ether);
        attempts[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        attempts[2] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        attempts[3] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        attempts[4] = abi.encodeWithSignature("pause()");
        attempts[5] = abi.encodeWithSignature("blacklist(address)", alice);
        attempts[6] = abi.encodeWithSignature("freezeAccount(address)", alice);
        attempts[7] = abi.encodeWithSignature("seize(address)", alice);
        attempts[8] = abi.encodeWithSignature("transferOwnership(address)", bob);
        attempts[9] = abi.encodeWithSignature("initialize(address)", bob);
        attempts[10] = abi.encodeWithSignature("upgradeTo(address)", bob);
        attempts[11] = abi.encodeWithSignature("setMinter(address)", bob);

        for (uint256 i; i < attempts.length; ++i) {
            (bool deployerSuccess,) = address(token).call(attempts[i]);
            assertFalse(deployerSuccess);
            vm.prank(bob);
            (bool outsiderSuccess,) = address(token).call(attempts[i]);
            assertFalse(outsiderSuccess);
        }
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function testFuzz_transfersConserveSupply(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, first);
        assertTrue(token.transfer(alice, first));
        vm.prank(alice);
        assertTrue(token.transfer(bob, second));
        assertEq(token.balanceOf(address(this)), SUPPLY - first);
        assertEq(token.balanceOf(alice), first - second);
        assertEq(token.balanceOf(bob), second);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromConservesSupplyAndSpendsAllowance(uint256 approved, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        approved = bound(approved, amount, type(uint256).max);
        assertTrue(token.approve(spender, approved));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.allowance(address(this), spender), approved == type(uint256).max ? approved : approved - amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_overdrawAlwaysReverts(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        token.transfer(alice, balance);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientAllowanceAlwaysReverts(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY - 1);
        amount = bound(amount, approved + 1, SUPPLY);
        token.approve(spender, approved);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, amount)
        );
        token.transferFrom(address(this), alice, amount);
        assertEq(token.allowance(address(this), spender), approved);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }
}
