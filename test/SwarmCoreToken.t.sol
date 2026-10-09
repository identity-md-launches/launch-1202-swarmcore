// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmCoreToken} from "../src/SwarmCoreToken.sol";
import {DeploySwarmCore} from "../script/DeploySwarmCore.s.sol";

contract SwarmCoreTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    SwarmCoreToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new SwarmCoreToken();
    }

    // --- metadata and supply ---------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "SwarmCore");
        assertEq(token.symbol(), "CORE");
        assertEq(token.decimals(), 18);
    }

    function test_wholeSupplyMintedOnceToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        SwarmCoreToken fresh = new SwarmCoreToken();
        assertEq(fresh.balanceOf(alice), SUPPLY);
    }

    function test_deployScriptMintsToCaller() public {
        DeploySwarmCore script = new DeploySwarmCore();
        SwarmCoreToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    // --- transfers -------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, alice, 1_000 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(alice);
        token.transfer(bob, 11);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    function test_selfTransferKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 5 ether);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_zeroTransferSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    // --- allowances ------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        assertTrue(token.approve(alice, 300 ether));
        assertEq(token.allowance(deployer, alice), 300 ether);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 200 ether));
        assertEq(token.balanceOf(bob), 200 ether);
        assertEq(token.allowance(deployer, alice), 100 ether);
    }

    function test_infiniteAllowanceIsNotSpent() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 5, 6));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 6);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    // --- no privileged powers --------------------------------------------------------------

    function test_noMintOwnerPauseOrSeizeEntryPoints() public {
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, SUPPLY);
        calls[1] = abi.encodeWithSignature("mint(uint256)", SUPPLY);
        calls[2] = abi.encodeWithSignature("owner()");
        calls[3] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[4] = abi.encodeWithSignature("pause()");
        calls[5] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[6] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[7] = abi.encodeWithSignature("burnFrom(address,uint256)", deployer, 1);
        calls[8] = abi.encodeWithSignature("initialize(address)", alice);
        calls[9] = abi.encodeWithSignature("setMinter(address)", alice);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // --- fuzz ------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromSpendsAllowanceExactly(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, SUPPLY);
        amount = bound(amount, 0, allowance);
        vm.prank(deployer);
        token.approve(alice, allowance);
        vm.prank(alice);
        token.transferFrom(deployer, bob, amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(deployer, alice), allowance - amount);
    }
}
