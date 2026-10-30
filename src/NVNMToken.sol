// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title  NVNM Token
 * @author NVNM Foundation Limited
 * @notice Fixed-supply ERC-20 for NVNM, with EIP-2612 permit.
 *
 * @dev COMPOSITION
 *
 *      This token composes two OpenZeppelin v5 modules, {ERC20} and
 *      {ERC20Permit}. It declares no state of its own, uses no assembly, and
 *      adds no logic beyond a constructor that mints the entire supply once.
 *
 *      BEHAVIOUR
 *
 *        - Every function behaves identically for every caller. The deployer,
 *          the treasury and NVNM Foundation Limited hold no special authority.
 *        - The code and parameters are fixed at deployment.
 *        - Supply is minted once, in the constructor, and stays constant.
 *        - Only a holder, or a spender it has approved, can move its tokens,
 *          and any holder can transfer its tokens at any time.
 *        - Transfers deliver the exact amount sent, balances change only
 *          through transfers, and holdings and transfer sizes are unlimited.
 *        - Tokens sent to this contract stay there permanently.
 *
 * @custom:security-contact security@nvnmchain.io
 */
contract NVNMToken is ERC20, ERC20Permit {
    /**
     * @notice Token name. Also the EIP-712 domain name, so it forms part of
     *         every {permit} signature.
     * @dev    {ERC20Permit} sets the domain version to "1", pinned by
     *         `test_Eip712DomainFields`.
     */
    string private constant _NAME = "NVNM Token";

    /// @notice Ticker symbol.
    string private constant _SYMBOL = "NVNM";

    /// @notice One billion tokens at 18 decimals, minted once in the constructor.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /**
     * @notice Mints {INITIAL_SUPPLY} to `recipient`.
     * @dev    A zero `recipient` is rejected by {ERC20-_mint} with
     *         {IERC20Errors-ERC20InvalidReceiver}.
     * @param recipient Receives the entire supply. The treasury Safe.
     */
    constructor(
        address recipient
    ) ERC20(_NAME, _SYMBOL) ERC20Permit(_NAME) {
        _mint(recipient, INITIAL_SUPPLY);
    }
}
