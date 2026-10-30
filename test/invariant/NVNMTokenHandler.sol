// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NVNMToken} from "../../src/NVNMToken.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title  NVNMTokenHandler
 * @notice Bounded entrypoint surface for the NVNM stateful invariant runs.
 * @dev    The invariant profile sets `fail_on_revert = true`, so every call
 *         made here must succeed: a transfer must stay within the sender's
 *         balance, and a transferFrom within both the caller's allowance and
 *         the owner's balance.
 */
contract NVNMTokenHandler is CommonBase, StdCheats, StdUtils {
    uint256 public constant ACTOR_COUNT = 8;

    NVNMToken public immutable token;

    address[] internal _actors;

    /* ------------------------------ GHOST STATE ----------------------------- */

    uint256 public ghostTotalTransferred;

    uint256 public callsTransfer;
    uint256 public callsApprove;
    uint256 public callsTransferFrom;

    constructor(
        NVNMToken token_
    ) {
        token = token_;

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            _actors.push(address(uint160(uint256(keccak256(abi.encodePacked("nvnm.actor", i))))));
        }
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function _actor(
        uint256 seed
    ) internal view returns (address) {
        return _actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }

    /// @dev Seeds the actor set. Called once from setUp, never by the fuzzer.
    function distribute(
        uint256 perActor
    ) external {
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            require(token.transfer(_actors[i], perActor), "distribute failed");
        }
    }

    /* ------------------------------ ENTRYPOINTS ----------------------------- */

    function transfer(
        uint256 actorSeed,
        uint256 toSeed,
        uint256 amount
    ) external {
        address from = _actor(actorSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        require(token.transfer(to, amount), "transfer returned false");

        ghostTotalTransferred += amount;
        callsTransfer++;
    }

    function approve(
        uint256 actorSeed,
        uint256 spenderSeed,
        uint256 amount
    ) external {
        address owner = _actor(actorSeed);
        address spender = _actor(spenderSeed);

        vm.prank(owner);
        token.approve(spender, amount);
        callsApprove++;
    }

    function transferFrom(
        uint256 callerSeed,
        uint256 fromSeed,
        uint256 toSeed,
        uint256 amount
    ) external {
        address caller = _actor(callerSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, caller);
        uint256 balance = token.balanceOf(from);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);

        vm.prank(caller);
        require(token.transferFrom(from, to, amount), "transferFrom returned false");

        ghostTotalTransferred += amount;
        callsTransferFrom++;
    }

    /* ------------------------------- REPORTING ------------------------------ */

    function callSummary() external view {
        console2.log("--- NVNMTokenHandler call summary ---");
        console2.log("transfer      :", callsTransfer);
        console2.log("approve       :", callsApprove);
        console2.log("transferFrom  :", callsTransferFrom);
        console2.log("total moved   :", ghostTotalTransferred);
    }
}
