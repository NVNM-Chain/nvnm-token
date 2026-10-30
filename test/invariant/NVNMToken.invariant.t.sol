// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NVNMToken} from "../../src/NVNMToken.sol";
import {NVNMTokenHandler} from "./NVNMTokenHandler.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title  NVNMTokenInvariantTest
 * @notice Stateful invariant coverage for the NVNM token.
 * @dev    Establishes the properties that hold under every sequence of
 *         transfers, approvals and allowance spends that the handler can
 *         generate.
 */
contract NVNMTokenInvariantTest is Test {
    NVNMToken internal token;
    NVNMTokenHandler internal handler;

    address internal treasury;
    address[] internal actors;

    function setUp() public {
        treasury = makeAddr("treasury");

        token = new NVNMToken(treasury);
        handler = new NVNMTokenHandler(token);

        uint256 supply = token.INITIAL_SUPPLY();
        vm.prank(treasury);
        require(token.transfer(address(handler), supply), "seed failed");

        handler.distribute(supply / (handler.ACTOR_COUNT() * 2));
        actors = handler.actors();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = NVNMTokenHandler.transfer.selector;
        selectors[1] = NVNMTokenHandler.approve.selector;
        selectors[2] = NVNMTokenHandler.transferFrom.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        vm.label(address(token), "NVNMToken");
        vm.label(address(handler), "Handler");
    }

    /// @notice The token has no mint or burn, so total supply cannot change no
    ///         matter what the fuzzer does.
    function invariant_TotalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY(), "totalSupply moved");
    }

    /// @notice Value is conserved across the complete set of holders.
    function invariant_SumOfBalancesEqualsTotalSupply() public view {
        uint256 sum = token.balanceOf(treasury) + token.balanceOf(address(handler));
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "value created or destroyed");
    }

    /// @notice Metadata cannot change.
    function invariant_MetadataIsImmutable() public view {
        assertEq(token.name(), "NVNM Token", "name");
        assertEq(token.symbol(), "NVNM", "symbol");
        assertEq(token.decimals(), 18, "decimals");
    }

    /// @notice Reports the handler call distribution.
    function invariant_CallSummary() public view {
        handler.callSummary();
    }
}
