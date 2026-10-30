// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NVNMToken} from "../src/NVNMToken.sol";
import {Config} from "./config/Config.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title  Deploy
 * @author NVNM Foundation Limited
 * @notice Deploys {NVNMToken}.
 *
 * @dev A deployment is final: the constructor mints the entire supply to the
 *      configured treasury, and the token's code and parameters are fixed from
 *      then on.
 *
 *      Ordering here is deliberate and must not be rearranged:
 *
 *        1. resolve config (fails closed on an unknown chain or unset address)
 *        2. pre-flight assertions — BEFORE any broadcast, so a misconfigured
 *           run costs nothing and cannot half-execute
 *        3. deploy the token; construction mints the supply in the same
 *           transaction
 *        4. assertions against the simulated token
 *        5. write a simulation record (never a confirmed deployment)
 *
 *      A production network (Ethereum mainnet or Base mainnet) additionally
 *      requires an explicit opt-in environment flag.
 *
 *      Use the Makefile's deploy targets. `--skip-simulation` takes gas limits
 *      from the network's node rather than Forge's simulation; see the note
 *      above the targets.
 *
 *      Usage (testnet):
 *        forge script script/Deploy.s.sol --rpc-url sepolia --account deployer \
 *          --broadcast --verify --skip-simulation
 *      Usage (production, --rpc-url mainnet or base):
 *        I_UNDERSTAND_THIS_IS_MAINNET=true \
 *        forge script script/Deploy.s.sol --rpc-url base --account deployer \
 *          --broadcast --verify --skip-simulation --slow
 */
contract Deploy is Config {
    /// @dev Thrown when a production run is attempted without the opt-in flag.
    error Deploy__MainnetOptInRequired();

    /// @dev Thrown when the deployer account holds no ETH.
    error Deploy__DeployerHasNoBalance(address deployer);

    /// @dev Thrown when a post-deploy assertion fails. Should be unreachable.
    error Deploy__PostDeployCheckFailed(string what);

    /// @dev Mirrors NVNMToken.INITIAL_SUPPLY for logging before deployment.
    uint256 internal constant NVNM_INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice The deployed token.
    NVNMToken public token;

    /// @notice Deploys the token.
    /// @return The deployed token.
    function run() external returns (NVNMToken) {
        NetworkConfig memory config = getConfig();

        _preflight(config);

        vm.startBroadcast();
        token = new NVNMToken(config.treasury);
        vm.stopBroadcast();

        assertDeployment(token, config.treasury);
        _writeArtifact(config);
        _logVerifyCommand(config);

        return token;
    }

    /* ------------------------------- PRE-FLIGHT ----------------------------- */

    function _preflight(
        NetworkConfig memory config
    ) internal view {
        console2.log("=== NVNM deployment pre-flight ===");
        console2.log("network      :", config.name);
        console2.log("chainId      :", config.chainId);
        console2.log("treasury     :", config.treasury);
        console2.log("initialSupply:", NVNM_INITIAL_SUPPLY);

        if (config.isMainnet && !vm.envOr("I_UNDERSTAND_THIS_IS_MAINNET", false)) {
            revert Deploy__MainnetOptInRequired();
        }

        address deployer = msg.sender;
        // Reject an unfunded signer; receiving ETH should remove this diagnostic.
        // This is not a claim that any positive balance covers deployment gas.
        // slither-disable-next-line incorrect-equality
        if (deployer.balance == 0) revert Deploy__DeployerHasNoBalance(deployer);
    }

    /* ---------------------------- POST-DEPLOY CHECK ------------------------- */

    /**
     * @notice Asserts a deployed token matches the specification exactly.
     * @dev    Public and parameterised so the same checks run against a live
     *         address from the test suite.
     * @param deployed The token to check.
     * @param treasury The address that should hold the entire supply.
     */
    function assertDeployment(
        NVNMToken deployed,
        address treasury
    ) public view {
        if (address(deployed).code.length == 0) revert Deploy__PostDeployCheckFailed("no code at address");
        if (keccak256(bytes(deployed.name())) != keccak256(bytes("NVNM Token"))) {
            revert Deploy__PostDeployCheckFailed("name");
        }
        if (keccak256(bytes(deployed.symbol())) != keccak256(bytes("NVNM"))) {
            revert Deploy__PostDeployCheckFailed("symbol");
        }
        if (deployed.decimals() != 18) revert Deploy__PostDeployCheckFailed("decimals");
        if (deployed.totalSupply() != NVNM_INITIAL_SUPPLY) revert Deploy__PostDeployCheckFailed("totalSupply");
        if (deployed.balanceOf(treasury) != deployed.totalSupply()) {
            revert Deploy__PostDeployCheckFailed("treasury does not hold full supply");
        }
        if (deployed.DOMAIN_SEPARATOR() == bytes32(0)) revert Deploy__PostDeployCheckFailed("permit domain");
    }

    /* ------------------------------- ARTIFACT ------------------------------- */

    function _writeArtifact(
        NetworkConfig memory config
    ) internal {
        string memory key = "nvnm-simulation";

        // Foundry accumulates fields under this key. Intermediate return values
        // are JSON snapshots; only the final snapshot below is written to disk.
        // slither-disable-start unused-return
        vm.serializeString(key, "status", "simulation");

        vm.serializeUint(key, "chainId", config.chainId);
        vm.serializeString(key, "network", config.name);
        vm.serializeString(key, "contractName", "NVNMToken");
        vm.serializeAddress(key, "token", address(token));
        vm.serializeAddress(key, "deployer", msg.sender);
        vm.serializeAddress(key, "treasury", config.treasury);
        vm.serializeUint(key, "initialSupply", NVNM_INITIAL_SUPPLY);
        vm.serializeUint(key, "simulationBlockNumber", block.number);
        vm.serializeBytes32(key, "codeHash", address(token).codehash);
        vm.serializeBytes(key, "constructorArgs", abi.encode(config.treasury));
        // slither-disable-end unused-return
        string memory json =
            vm.serializeString(key, "note", "Unconfirmed simulation; finalize from a successful receipt.");

        string memory directory = "deployments/simulations";
        vm.createDir(directory, true);
        string memory path = string.concat(directory, "/", vm.toString(config.chainId), "-", config.name, ".json");
        vm.writeJson(json, path);
        console2.log("UNCONFIRMED simulation written:", path);
    }

    function _logVerifyCommand(
        NetworkConfig memory config
    ) internal view {
        console2.log("=== verify the token ===");
        console2.log(
            string.concat(
                "forge verify-contract ",
                vm.toString(address(token)),
                " src/NVNMToken.sol:NVNMToken --chain-id ",
                vm.toString(config.chainId),
                " --constructor-args ",
                vm.toString(abi.encode(config.treasury)),
                " --etherscan-api-key $ETHERSCAN_API_KEY --watch"
            )
        );
    }
}
