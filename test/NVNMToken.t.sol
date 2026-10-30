// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NVNMToken} from "../src/NVNMToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title  NVNMTokenTest
 * @notice Core coverage for the NVNM token: construction and ERC-20 behaviour.
 * @dev    Permit is covered in NVNMTokenPermit.t.sol. Beyond ordinary
 *         ERC-20 behaviour, the tests that matter most establish that every
 *         account, including the deployer and the treasury, is treated alike.
 */
contract NVNMTokenTest is Test, IERC20Errors {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    NVNMToken internal token;

    address internal treasury;
    address internal alice;
    address internal bob;
    address internal attacker;

    function setUp() public {
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        token = new NVNMToken(treasury);

        vm.label(address(token), "NVNMToken");
    }

    function _fund(
        address to,
        uint256 amount
    ) internal {
        vm.prank(treasury);
        assertTrue(token.transfer(to, amount), "_fund failed");
    }

    /* =========================================================================
                                   CONSTRUCTION
    ========================================================================= */

    /// @notice Metadata and supply match the specification after deployment.
    function test_InitialState() public view {
        assertEq(token.name(), "NVNM Token", "name");
        assertEq(token.symbol(), "NVNM", "symbol");
        assertEq(token.decimals(), 18, "decimals");
        assertEq(token.totalSupply(), SUPPLY, "totalSupply");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY, "INITIAL_SUPPLY");
        assertEq(token.balanceOf(treasury), SUPPLY, "treasury holds all");
    }

    /// @notice The mint emits a single Transfer from the zero address.
    function test_ConstructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), treasury, SUPPLY);
        new NVNMToken(treasury);
    }

    /// @notice The deployer receives nothing. The whole supply goes to the
    ///         recipient named in the constructor.
    function test_DeployerReceivesNothing() public view {
        assertEq(token.balanceOf(address(this)), 0, "deployer balance");
    }

    /// @notice A zero recipient is rejected, so the supply cannot be minted to
    ///         an address nobody controls.
    function test_Revert_ConstructorRejectsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidReceiver.selector, address(0)));
        new NVNMToken(address(0));
    }

    /* =========================================================================
                                      ERC-20
    ========================================================================= */

    /// @notice Transfers move exactly the stated amount.
    function test_Transfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(treasury, alice, 100e18);
        vm.prank(treasury);
        assertTrue(token.transfer(alice, 100e18), "returns true");
        assertEq(token.balanceOf(alice), 100e18, "alice");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    /// @notice A self-transfer is balance-neutral.
    function test_TransferToSelfIsBalanceNeutral() public {
        _fund(alice, 500e18);
        vm.prank(alice);
        token.transfer(alice, 500e18);
        assertEq(token.balanceOf(alice), 500e18, "self-transfer changed balance");
    }

    /// @notice Overspending reverts with the exact balance and requirement.
    function test_Revert_TransferInsufficientBalance() public {
        _fund(alice, 10e18);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        vm.prank(alice);
        token.transfer(bob, 11e18);
    }

    /// @notice Transfer to the zero address is rejected.
    function test_Revert_TransferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidReceiver.selector, address(0)));
        vm.prank(treasury);
        token.transfer(address(0), 1e18);
    }

    /// @notice An approval sets the allowance exactly and emits Approval.
    function test_Approve() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(alice, bob, 60e18);
        vm.prank(alice);
        assertTrue(token.approve(bob, 60e18), "returns true");
        assertEq(token.allowance(alice, bob), 60e18, "allowance");
    }

    /// @notice Approving the zero address is rejected.
    function test_Revert_ApproveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 1e18);
    }

    /// @notice A finite allowance is decremented by exactly the amount spent.
    function test_TransferFromDecrementsAllowance() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 60e18);
        vm.prank(bob);
        token.transferFrom(alice, attacker, 25e18);
        assertEq(token.allowance(alice, bob), 35e18, "allowance");
        assertEq(token.balanceOf(attacker), 25e18, "recipient");
    }

    /// @notice An infinite allowance is not decremented (OZ v5 behaviour).
    function test_InfiniteAllowanceNotDecremented() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, attacker, 40e18);
        assertEq(token.allowance(alice, bob), type(uint256).max, "still infinite");
    }

    /// @notice Spending beyond the allowance reverts with the exact figures.
    function test_Revert_TransferFromExceedsAllowance() public {
        _fund(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientAllowance.selector, bob, 10e18, 11e18));
        vm.prank(bob);
        token.transferFrom(alice, bob, 11e18);
    }

    /// @notice Supply is conserved across arbitrary transfers.
    function testFuzz_TransferConservesSupply(
        uint256 amount
    ) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(treasury);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(treasury) + token.balanceOf(alice), SUPPLY, "conservation");
        assertEq(token.totalSupply(), SUPPLY, "totalSupply");
    }

    /* =========================================================================
                              EVERY CALLER IS ALIKE

       The complete callable ABI is checked by script/check-abi.py. Selector-
       only calls cannot establish absence: missing arguments also make an
       existing Solidity entrypoint revert during ABI decoding.
    ========================================================================= */

    /// @notice Without an allowance, nobody can move another account's tokens —
    ///         not the deployer, not the treasury that received the supply, and
    ///         not an arbitrary caller.
    function test_NoAccountCanMoveAnotherAccountsTokens() public {
        _fund(alice, 100e18);

        address[3] memory callers = [address(this), treasury, attacker];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientAllowance.selector, callers[i], 0, 100e18));
            vm.prank(callers[i]);
            token.transferFrom(alice, callers[i], 100e18);
        }

        assertEq(token.balanceOf(alice), 100e18, "balance untouched");
    }
}
