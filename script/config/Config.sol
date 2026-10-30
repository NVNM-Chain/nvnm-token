// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";

/**
 * @title  Config
 * @author NVNM Foundation Limited
 * @notice Per-network deployment parameters for NVNM.
 * @dev    Resolution is explicit and fails closed. There is no default branch:
 *         an unrecognised chain id reverts rather than silently deploying with
 *         someone else's parameters, and a production deployment with an
 *         unconfigured treasury is impossible by construction.
 *
 *         The token's only deployment parameter is the treasury, which
 *         receives the entire supply. Production networks (Ethereum mainnet
 *         and Base mainnet) take it from a compile-time constant rather than
 *         an environment variable: the address that receives every token
 *         belongs in version control, visible in a reviewed diff, not in an
 *         operator's shell.
 *
 *         Each production network carries its own treasury. Base is a distinct
 *         chain: an address that is a Safe on Ethereum is not necessarily
 *         controllable at the same address on Base, so the two are never
 *         assumed to be equal and are never shared between branches.
 */
abstract contract Config is Script {
    /* -------------------------------- ERRORS -------------------------------- */

    /// @dev The current chain has no entry in this file.
    error Config__UnsupportedChain(uint256 chainId);

    /// @dev A required address for this chain has not been filled in yet.
    error Config__AddressNotConfigured(uint256 chainId, string which);

    /* ------------------------------- CHAIN IDS ------------------------------ */

    uint256 internal constant CHAIN_MAINNET = 1;
    uint256 internal constant CHAIN_SEPOLIA = 11155111;
    uint256 internal constant CHAIN_HOODI = 560048;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_BASE_SEPOLIA = 84532;
    uint256 internal constant CHAIN_ANVIL = 31337;

    /* -------------------------------- TYPES --------------------------------- */

    struct NetworkConfig {
        uint256 chainId;
        string name;
        string explorer;
        /// @dev Receives 100% of supply.
        address treasury;
        /// @dev True for a production network — Ethereum mainnet or Base
        ///      mainnet. Gates the deployment opt-in.
        bool isMainnet;
    }

    /* ------------------------ PRODUCTION TREASURIES ------------------------- */

    /**
     * @dev The two production constants below are zero until governance
     *      approves the addresses. That is an enforced state, not an omission:
     *      {_requireConfigured} reverts with {Config__AddressNotConfigured} on
     *      a zero, so no production deployment can occur — by simulation,
     *      accident or haste — before the address lands in a reviewed diff.
     *      Setting them is a configuration change; it alters no logic, and the
     *      guard being asserted here is the guard under review.
     */

    /**
     * @dev The approved treasury Safe on Ethereum mainnet. Receives the entire
     *      supply. Unrecoverable if wrong: only the treasury itself can ever
     *      move the tokens minted to it.
     */
    address internal constant MAINNET_TREASURY = address(0);

    /**
     * @dev Base counterpart of {MAINNET_TREASURY}. Same requirements. Base is a
     *      separate chain with separate contract accounts: a Safe address from
     *      Ethereum is not controllable here unless it has been deployed to the
     *      same address by the same factory, with the same salt, under the same
     *      owner set. Confirm control on Base itself rather than assuming
     *      address parity.
     */
    address internal constant BASE_TREASURY = address(0);

    /* ------------------------------ RESOLUTION ------------------------------ */

    /// @notice Resolves the config for the chain the script is running against.
    /// @return The resolved configuration for the current chain.
    function getConfig() public view returns (NetworkConfig memory) {
        return getConfig(block.chainid);
    }

    /// @notice Resolves the config for an explicit chain id. Testable without forking.
    /// @param  chainId The chain to resolve parameters for.
    /// @return config  The resolved network configuration.
    function getConfig(
        uint256 chainId
    ) public view returns (NetworkConfig memory config) {
        if (chainId == CHAIN_MAINNET) {
            config = NetworkConfig({
                chainId: CHAIN_MAINNET,
                name: "mainnet",
                explorer: "https://etherscan.io",
                treasury: MAINNET_TREASURY,
                isMainnet: true
            });
        } else if (chainId == CHAIN_SEPOLIA) {
            config = NetworkConfig({
                chainId: CHAIN_SEPOLIA,
                name: "sepolia",
                explorer: "https://sepolia.etherscan.io",
                treasury: _treasuryFromEnv(),
                isMainnet: false
            });
        } else if (chainId == CHAIN_HOODI) {
            config = NetworkConfig({
                chainId: CHAIN_HOODI,
                name: "hoodi",
                explorer: "https://hoodi.etherscan.io",
                treasury: _treasuryFromEnv(),
                isMainnet: false
            });
        } else if (chainId == CHAIN_BASE) {
            config = NetworkConfig({
                chainId: CHAIN_BASE,
                name: "base",
                explorer: "https://basescan.org",
                treasury: BASE_TREASURY,
                isMainnet: true
            });
        } else if (chainId == CHAIN_BASE_SEPOLIA) {
            config = NetworkConfig({
                chainId: CHAIN_BASE_SEPOLIA,
                name: "base-sepolia",
                explorer: "https://sepolia.basescan.org",
                treasury: _treasuryFromEnv(),
                isMainnet: false
            });
        } else if (chainId == CHAIN_ANVIL) {
            config = NetworkConfig({
                chainId: CHAIN_ANVIL,
                name: "anvil",
                explorer: "",
                treasury: _treasuryFromEnvOrAnvilDefault(),
                isMainnet: false
            });
        } else {
            revert Config__UnsupportedChain(chainId);
        }

        _requireConfigured(chainId, config.treasury);
    }

    /* -------------------------------- HELPERS ------------------------------- */

    /// @dev The treasury must be set. The token itself rejects a zero
    ///      recipient as well; failing here reports which chain is missing it
    ///      before anything is simulated.
    function _requireConfigured(
        uint256 chainId,
        address treasury
    ) internal pure {
        if (treasury == address(0)) revert Config__AddressNotConfigured(chainId, "treasury");
    }

    /// @dev Overridable so tests can inject an address without `vm.setEnv`,
    ///      which mutates process-global state and races because forge runs a
    ///      suite's test functions in parallel.
    function _treasuryFromEnv() internal view virtual returns (address) {
        return vm.envOr("TREASURY", address(0));
    }

    /// @dev Local-only convenience: falls back to anvil's default account #0.
    function _treasuryFromEnvOrAnvilDefault() internal view virtual returns (address) {
        address treasury = _treasuryFromEnv();
        return treasury == address(0) ? 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 : treasury;
    }
}
