// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmCoreToken} from "src/SwarmCoreToken.sol";

/// @dev Extends the existing examples with boundaries, failure atomicity, and algebraic properties.
/// forge-config: default.fuzz.runs = 1000
contract SwarmCoreTokenPropertiesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SwarmCoreToken private token;
    address private owner = makeAddr("CORE owner");
    address private alice = makeAddr("CORE alice");
    address private bob = makeAddr("CORE bob");
    address private spender = makeAddr("CORE spender");

    function setUp() public {
        vm.prank(owner);
        token = new SwarmCoreToken();
    }

    function test_constructorEmitsExactlyOneMintAndUsesSenderNotOrigin() public {
        vm.recordLogs();
        vm.prank(alice, bob);
        SwarmCoreToken fresh = new SwarmCoreToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(alice), SUPPLY);
        assertEq(fresh.balanceOf(bob), 0);
        assertEq(fresh.balanceOf(address(fresh)), 0);
        assertEq(fresh.balanceOf(address(0)), 0);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_directTransferEdgesAndRoundTrips() public {
        uint256[3] memory amounts = [uint256(0), uint256(1), SUPPLY];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            vm.expectEmit(true, true, false, true, address(token));
            emit IERC20.Transfer(owner, alice, amount);
            vm.prank(owner);
            assertTrue(token.transfer(alice, amount));
            _assertBalances(SUPPLY - amount, amount, 0);
            vm.prank(alice);
            assertTrue(token.transfer(owner, amount));
            _assertBalances(SUPPLY, 0, 0);
        }
    }

    function test_maximumTransferRevertsWithoutChangingBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY, type(uint256).max)
        );
        vm.prank(owner);
        token.transfer(alice, type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY, SUPPLY + 1)
        );
        vm.prank(owner);
        token.transfer(owner, SUPPLY + 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroTransferToZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_approvalEdgesReplaceRatherThanAddAndEmitEvents() public {
        uint256[5] memory amounts = [type(uint256).max, type(uint256).max - 1, uint256(1), uint256(0), SUPPLY];
        // An account needs no balance to approve; approval itself must not move tokens.
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectEmit(true, true, false, true, address(token));
            emit IERC20.Approval(alice, spender, amounts[i]);
            vm.prank(alice);
            assertTrue(token.approve(spender, amounts[i]));
            assertEq(token.allowance(alice, spender), amounts[i]);
            assertEq(token.allowance(owner, spender), 0);
            assertEq(token.allowance(alice, bob), 0);
            _assertBalances(SUPPLY, 0, 0);
        }
    }

    function test_revokingInfiniteApprovalPreventsFurtherSpending() public {
        _approve(owner, spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, 1));
        assertEq(token.allowance(owner, spender), type(uint256).max);
        _approve(owner, spender, 0);
        _expectAllowanceFailure(owner, alice, spender, 0, 1);
        _assertBalances(SUPPLY - 1, 1, 0);
        assertEq(token.allowance(owner, spender), 0);
    }

    function test_exhaustedAllowanceCannotBeSpentTwice() public {
        _approve(owner, spender, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(owner, alice, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, 1));
        assertEq(token.allowance(owner, spender), 0);
        _expectAllowanceFailure(owner, alice, spender, 0, 1);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_delegatedSelfTransferConsumesFiniteAllowance() public {
        _approve(owner, spender, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(owner, owner, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, owner, SUPPLY));
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(owner, spender), 0);
        _expectAllowanceFailure(owner, owner, spender, 0, 1);
    }

    function test_ownerUsingTransferFromNeedsSelfApproval() public {
        _expectAllowanceFailure(owner, alice, owner, 0, 1);
        _approve(owner, owner, 1);
        vm.prank(owner);
        assertTrue(token.transferFrom(owner, alice, 1));
        assertEq(token.allowance(owner, owner), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_deployerCannotSpendAnotherHoldersTokens() public {
        vm.prank(owner);
        assertTrue(token.transfer(alice, 10));
        _approve(alice, spender, 10);
        _expectAllowanceFailure(alice, owner, owner, 0, 1);
        assertEq(token.allowance(alice, spender), 10);
        _assertBalances(SUPPLY - 10, 10, 0);
    }

    function test_approvalCannotBeUsedByAnotherSpenderOrForAnotherOwner() public {
        _approve(owner, spender, SUPPLY);
        _expectAllowanceFailure(owner, bob, alice, 0, 1);
        _expectAllowanceFailure(alice, bob, spender, 0, 1);
        assertEq(token.allowance(owner, spender), SUPPLY);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroTransferFromNeedsNeitherBalanceNorAllowanceAndEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_fullSupplyCanMoveRepeatedlyWithInfiniteApproval() public {
        _approve(owner, spender, type(uint256).max);
        _approve(alice, spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(owner, alice, SUPPLY));
        _assertBalances(0, SUPPLY, 0);
        assertTrue(token.transferFrom(alice, owner, SUPPLY));
        vm.stopPrank();
        _assertBalances(SUPPLY, 0, 0);
        assertEq(token.allowance(owner, spender), type(uint256).max);
        assertEq(token.allowance(alice, spender), type(uint256).max);
    }

    function test_maxMinusOneAllowanceIsFinite() public {
        _approve(owner, spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, 1));
        assertEq(token.allowance(owner, spender), type(uint256).max - 2);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_infiniteApprovalCannotCreateBalance() public {
        _approve(alice, spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, type(uint256).max)
        );
        vm.prank(spender);
        token.transferFrom(alice, bob, type(uint256).max);
        assertEq(token.allowance(alice, spender), type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_failedTransferFromPreservesAllowanceForRetryAfterFunding() public {
        _approve(alice, spender, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), 1);
        _assertBalances(SUPPLY, 0, 0);
        vm.prank(owner);
        assertTrue(token.transfer(alice, 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.allowance(alice, spender), 0);
        _assertBalances(SUPPLY - 1, 0, 1);
    }

    function test_zeroSpenderRejectedEvenWhenRevoking() public {
        _approve(owner, spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), 0);
        assertEq(token.allowance(owner, spender), 10);
        assertEq(token.allowance(owner, address(0)), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_tokenContractCanReceiveTokensWithoutBurningThem() public {
        vm.prank(owner);
        assertTrue(token.transfer(address(token), SUPPLY));
        assertEq(token.balanceOf(address(token)), SUPPLY);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(owner);
        assertTrue(token.transfer(alice, amount));
        _assertBalances(SUPPLY - amount, amount, 0);
        vm.prank(alice);
        assertTrue(token.transfer(owner, amount));
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_splitTransfersEqualSingleTransfer(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        vm.prank(owner);
        SwarmCoreToken single = new SwarmCoreToken();
        vm.startPrank(owner);
        assertTrue(single.transfer(alice, total));
        assertTrue(token.transfer(alice, first));
        assertTrue(token.transfer(alice, total - first));
        vm.stopPrank();
        assertEq(token.balanceOf(owner), single.balanceOf(owner));
        assertEq(token.balanceOf(alice), single.balanceOf(alice));
        _assertBalances(SUPPLY - total, total, 0);
    }

    function testFuzz_transferAboveBalanceIsAtomic(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - balance);
        vm.prank(owner);
        assertTrue(token.transfer(alice, balance));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + excess)
        );
        vm.prank(alice);
        token.transfer(bob, balance + excess);
        _assertBalances(SUPPLY - balance, balance, 0);
    }

    function testFuzz_transferFromAboveAllowanceIsAtomic(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - allowed);
        _approve(owner, spender, allowed);
        _expectAllowanceFailure(owner, alice, spender, allowed, allowed + excess);
        assertEq(token.allowance(owner, spender), allowed);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_transferFromAboveBalanceRollsBackFiniteAllowance(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max - 1);
        vm.prank(owner);
        assertTrue(token.transfer(alice, balance));
        _approve(alice, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), amount);
        _assertBalances(SUPPLY - balance, balance, 0);
    }

    function testFuzz_invalidRecipientRollsBackDelegatedAllowance(uint256 amount, bool infinite) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 allowed = infinite ? type(uint256).max : amount;
        _approve(owner, spender, allowed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
        assertEq(token.allowance(owner, spender), allowed);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_replacingApprovalLimitsCumulativeSpending(uint256 first, uint256 replacement, uint256 spent)
        public
    {
        replacement = bound(replacement, 0, SUPPLY - 1);
        spent = bound(spent, 0, replacement);
        _approve(owner, spender, first);
        _approve(owner, spender, replacement);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, spent));
        uint256 remaining = replacement - spent;
        assertEq(token.allowance(owner, spender), remaining);
        _expectAllowanceFailure(owner, alice, spender, remaining, remaining + 1);
        assertEq(token.allowance(owner, spender), remaining);
        _assertBalances(SUPPLY - spent, spent, 0);
    }

    function testFuzz_spenderAllowancesAreIndependent(uint256 first, uint256 second, uint256 spent) public {
        spent = bound(spent, 0, first < SUPPLY ? first : SUPPLY);
        _approve(owner, spender, first);
        _approve(owner, bob, second);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, alice, spent));
        assertEq(token.allowance(owner, bob), second);
        assertEq(token.allowance(owner, spender), first == type(uint256).max ? first : first - spent);
        _assertBalances(SUPPLY - spent, spent, 0);
    }

    function _approve(address holder, address delegate, uint256 amount) private {
        vm.prank(holder);
        assertTrue(token.approve(delegate, amount));
        assertEq(token.allowance(holder, delegate), amount);
    }

    function _expectAllowanceFailure(address holder, address to, address caller, uint256 allowed, uint256 amount)
        private
    {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, allowed, amount)
        );
        vm.prank(caller);
        token.transferFrom(holder, to, amount);
    }

    function _assertBalances(uint256 ownerBalance, uint256 aliceBalance, uint256 bobBalance) private view {
        assertEq(token.balanceOf(owner), ownerBalance);
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
