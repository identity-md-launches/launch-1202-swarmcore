// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmCoreToken} from "src/SwarmCoreToken.sol";

/// @dev Closed set of holders: every successful transfer stays among these four actors.
/// Ghost balances and allowances are derived from requested operations, never copied from token reads.
/// No token storage is written by cheatcodes. Expected failures must leave this model unchanged.
contract SwarmCoreTokenHandler is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SwarmCoreToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(SwarmCoreToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors_[0]] = SUPPLY / 2;
        expectedBalance[actors_[1]] = SUPPLY / 4;
        expectedBalance[actors_[2]] = SUPPLY / 4;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _amount(amountSeed, expectedBalance[from]));
    }

    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), expectedBalance[from]);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 mode = amountSeed % 5;
        uint256 amount = mode == 0
            ? 0
            : mode == 1 ? type(uint256).max : mode == 2 ? type(uint256).max - 1 : bound(amountSeed, 1, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 amount = _amount(amountSeed, allowed < balance ? allowed : balance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, _actor(toSeed), amount));
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] = allowed - amount;
        _move(owner, _actor(toSeed), amount);
    }

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = balance + bound(excessSeed, 1, type(uint256).max - balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(_actor(toSeed), amount);
    }

    function transferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        // Finite approvals exercise rollback of the allowance decrement before _transfer reverts.
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), amount);
    }

    function revokeAndTrySpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _approve(owner, spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), 1);
    }

    function invalidRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        if (delegated) _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(delegated ? spender : owner);
        if (delegated) token.transferFrom(owner, address(0), amount);
        else token.transfer(address(0), amount);
    }

    function invalidSpender(uint256 ownerSeed, uint256 amount) external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(_actor(ownerSeed));
        token.approve(address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _move(address from, address to, uint256 amount) private {
        // Sequential updates intentionally account for from == to as well.
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        // Explicitly include zero, one minor unit, and the entire available amount during sequences.
        uint256 mode = seed % 4;
        if (mode == 0 || maximum == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return maximum;
        return bound(seed, 0, maximum);
    }
}

/// @dev The requested fixed supply and exact ERC-20 accounting must survive every handler call.
/// fail_on_revert prevents a failed assertion or an unexpected rejection being discarded by Forge.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmCoreTokenInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SwarmCoreToken private token;
    SwarmCoreTokenHandler private handler;
    address[4] private actors;

    function setUp() public {
        actors = [
            makeAddr("CORE deployer"), makeAddr("CORE holder A"), makeAddr("CORE holder B"), makeAddr("CORE holder C")
        ];
        vm.prank(actors[0]);
        token = new SwarmCoreToken();
        vm.startPrank(actors[0]);
        assertTrue(token.transfer(actors[1], SUPPLY / 4));
        assertTrue(token.transfer(actors[2], SUPPLY / 4));
        vm.stopPrank();
        handler = new SwarmCoreTokenHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferAll.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.transferAboveBalance.selector;
        selectors[5] = handler.transferFromAboveBalance.selector;
        selectors[6] = handler.revokeAndTrySpend.selector;
        selectors[7] = handler.invalidRecipient.selector;
        selectors[8] = handler.invalidSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyAndMetadata() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.name(), "SwarmCore");
        assertEq(token.symbol(), "CORE");
        assertEq(token.decimals(), 18);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allBalancesMatchAuthorizedMovementsAndConserveSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 actual = token.balanceOf(actors[i]);
            assertEq(actual, handler.expectedBalance(actors[i]), "unauthorized balance change or incorrect transfer");
            sum += actual;
        }
        assertEq(sum, SUPPLY, "tokens created, burned, taxed, or diverted from the tracked holders");
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulSpending() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.allowance(actors[i], address(0)), 0);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "approval isolation, spending, revocation, or failed-call rollback violated"
                );
            }
        }
    }

    /// @dev A holder must still be able to move its full balance after every random sequence.
    function afterInvariant() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transferAll(i, 0);
            assertEq(token.balanceOf(actors[i]), 0);
        }
        assertEq(token.balanceOf(actors[0]), SUPPLY);
        invariant_fixedSupplyAndMetadata();
        invariant_allBalancesMatchAuthorizedMovementsAndConserveSupply();
        invariant_allowancesMatchApprovalsAndSuccessfulSpending();
    }

    /// @dev Deterministic exercise of the handler's positive and negative branches complements fuzz statistics.
    function test_handlerExercisesPositiveSpendsSelfTransfersAndFailureRollback() public {
        handler.approve(0, 3, 3); // finite approval of three minor units
        handler.transferFrom(0, 3, 1, 1);
        assertEq(token.balanceOf(actors[1]), SUPPLY / 4 + 1);
        assertEq(token.allowance(actors[0], actors[3]), 2);
        handler.transferFrom(0, 3, 0, 1); // self-transfer consumes one unit of allowance
        assertEq(token.allowance(actors[0], actors[3]), 1);
        handler.transferFromAboveBalance(0, 3, 1, false);
        handler.transferFromAboveBalance(1, 3, 0, true);
        handler.invalidRecipient(0, 3, 1, true);
        handler.invalidRecipient(0, 3, 0, false);
        handler.invalidSpender(0, type(uint256).max);
        handler.transferAboveBalance(1, 0, type(uint256).max);
        handler.revokeAndTrySpend(0, 3, 1);
        handler.approve(0, 3, 1); // infinite allowance
        handler.transferFrom(0, 3, 2, 2); // whole balance
        assertEq(token.allowance(actors[0], actors[3]), type(uint256).max);
        handler.transfer(2, 2, 2); // whole-balance self-transfer
        invariant_fixedSupplyAndMetadata();
        invariant_allBalancesMatchAuthorizedMovementsAndConserveSupply();
        invariant_allowancesMatchApprovalsAndSuccessfulSpending();
        afterInvariant();
    }
}
