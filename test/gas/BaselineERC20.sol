// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title  BaselineERC20
 * @notice BENCHMARK FIXTURE — NEVER DEPLOY.
 * @dev    An unmodified OpenZeppelin ERC20 with NVNM's name, symbol, decimals
 *         and supply, and nothing else: no permit.
 *
 *         It exists only as the denominator for the gas report, so that the
 *         running cost of adding permit is a measured delta against the
 *         simplest token that could serve the same purpose, rather than an
 *         assertion. Lives under test/ because it is never deployed and must
 *         not be mistaken for part of the audit scope.
 */
contract BaselineERC20 is ERC20 {
    constructor(
        address recipient
    ) ERC20("NVNM Token", "NVNM") {
        _mint(recipient, 1_000_000_000 * 1e18);
    }
}
