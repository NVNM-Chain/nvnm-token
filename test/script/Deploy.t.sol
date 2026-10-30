// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Deploy} from "../../script/Deploy.s.sol";
import {VerifyDeployment} from "../../script/VerifyDeployment.s.sol";
import {Config} from "../../script/config/Config.sol";
import {NVNMToken} from "../../src/NVNMToken.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Injects the treasury without touching process-global environment
///      variables, which race because forge runs a suite's test functions in
///      parallel.
contract DeployHarness is Deploy {
    address internal injected;

    constructor(
        address treasury
    ) {
        injected = treasury;
    }

    function _treasuryFromEnv() internal view override returns (address) {
        return injected;
    }

    function _treasuryFromEnvOrAnvilDefault() internal view override returns (address) {
        return injected;
    }
}

/// @dev A token with the right metadata but the wrong supply, used to prove the
///      post-deploy checks are not vacuous.
contract WrongSupplyToken {
    function name() external pure returns (string memory) {
        return "NVNM Token";
    }

    function symbol() external pure returns (string memory) {
        return "NVNM";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 42;
    }

    function balanceOf(
        address
    ) external pure returns (uint256) {
        return 42;
    }

    function INITIAL_SUPPLY() external pure returns (uint256) {
        return 42;
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/**
 * @title  DeployTest
 * @notice Coverage for the deployment layer: chain resolution, the fail-closed
 *         treasury configuration, the post-deploy conformance checks and the
 *         independent verifier. Nothing here broadcasts.
 */
contract DeployTest is Test {
    DeployHarness internal deployScript;
    DeployHarness internal unconfiguredScript;
    VerifyDeployment internal verifyScript;

    address internal treasury;

    function setUp() public {
        treasury = makeAddr("treasury");

        deployScript = new DeployHarness(treasury);
        unconfiguredScript = new DeployHarness(address(0));
        verifyScript = new VerifyDeployment();
    }

    /* ------------------------------- CONFIG --------------------------------- */

    /// @notice Every supported chain resolves with the expected metadata.
    function test_ConfigResolvesSupportedChains() public view {
        Config.NetworkConfig memory sepolia = deployScript.getConfig(11155111);
        assertEq(sepolia.name, "sepolia", "sepolia name");
        assertEq(sepolia.treasury, treasury, "treasury injected");
        assertFalse(sepolia.isMainnet, "not mainnet");

        Config.NetworkConfig memory hoodi = deployScript.getConfig(560048);
        assertEq(hoodi.explorer, "https://hoodi.etherscan.io", "hoodi explorer");

        Config.NetworkConfig memory baseSepolia = deployScript.getConfig(84532);
        assertEq(baseSepolia.name, "base-sepolia", "base sepolia name");
        assertEq(baseSepolia.explorer, "https://sepolia.basescan.org", "base sepolia explorer");
        assertEq(baseSepolia.treasury, treasury, "treasury injected");
        assertFalse(baseSepolia.isMainnet, "not a production network");

        Config.NetworkConfig memory anvil = deployScript.getConfig(31337);
        assertEq(anvil.name, "anvil", "anvil name");
    }

    /// @notice An unknown chain id is rejected rather than silently defaulted.
    function test_Revert_ConfigUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(Config.Config__UnsupportedChain.selector, uint256(999)));
        deployScript.getConfig(999);
    }

    /// @notice Neither production network can resolve while its treasury is
    ///         unset. This is the guard that makes an accidental or premature
    ///         production deployment impossible before the address is reviewed.
    ///         Base carries its own treasury, so configuring Ethereum mainnet
    ///         does not silently unlock Base or vice versa.
    function test_Revert_MainnetTreasuryNotConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(Config.Config__AddressNotConfigured.selector, uint256(1), "treasury"));
        deployScript.getConfig(1);

        vm.expectRevert(abi.encodeWithSelector(Config.Config__AddressNotConfigured.selector, uint256(8453), "treasury"));
        deployScript.getConfig(8453);
    }

    /// @notice A testnet with nothing injected also fails closed.
    function test_Revert_TestnetTreasuryNotConfigured() public {
        vm.expectRevert(
            abi.encodeWithSelector(Config.Config__AddressNotConfigured.selector, uint256(11155111), "treasury")
        );
        unconfiguredScript.getConfig(11155111);
    }

    /* --------------------------- POST-DEPLOY CHECKS -------------------------- */

    /// @notice A correct deployment passes the conformance assertions.
    function test_AssertDeploymentAcceptsCorrectDeployment() public {
        NVNMToken token = new NVNMToken(treasury);
        deployScript.assertDeployment(token, treasury);
    }

    /// @notice A token with the right metadata but the wrong supply is rejected.
    function test_Revert_AssertDeploymentRejectsWrongSupply() public {
        WrongSupplyToken wrong = new WrongSupplyToken();
        vm.expectRevert(abi.encodeWithSelector(Deploy.Deploy__PostDeployCheckFailed.selector, "totalSupply"));
        deployScript.assertDeployment(NVNMToken(address(wrong)), treasury);
    }

    /// @notice A deployment whose supply landed on the wrong address is rejected.
    function test_Revert_AssertDeploymentRejectsWrongTreasury() public {
        NVNMToken token = new NVNMToken(makeAddr("notTheTreasury"));
        vm.expectRevert(
            abi.encodeWithSelector(Deploy.Deploy__PostDeployCheckFailed.selector, "treasury does not hold full supply")
        );
        deployScript.assertDeployment(token, treasury);
    }

    /// @notice An address with no code is rejected.
    function test_Revert_AssertDeploymentRejectsEmptyAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.Deploy__PostDeployCheckFailed.selector, "no code at address"));
        deployScript.assertDeployment(NVNMToken(makeAddr("nothing")), treasury);
    }

    function test_DeployRunOnlyWritesSimulation() public {
        vm.chainId(31337);
        vm.deal(address(this), 10 ether);
        string memory simulation = "deployments/simulations/31337-anvil.json";
        bool hadSimulation = vm.exists(simulation);
        string memory simulationBefore = hadSimulation ? vm.readFile(simulation) : "";
        NVNMToken token = deployScript.run();
        string memory record = vm.readFile(simulation);
        assertEq(vm.parseJsonString(record, ".status"), "simulation", "status");
        assertEq(vm.parseJsonAddress(record, ".token"), address(token), "token");
        assertEq(vm.parseJsonAddress(record, ".treasury"), treasury, "treasury");
        assertEq(token.balanceOf(treasury), token.totalSupply(), "treasury holds supply");
        string memory confirmed =
            string.concat("deployments/31337-", vm.toLowercase(vm.toString(address(token))), ".json");
        assertFalse(vm.exists(confirmed), "dry run created a confirmed record");
        if (hadSimulation) vm.writeFile(simulation, simulationBefore);
        else vm.removeFile(simulation);
    }

    /* --------------------------- LIVE VERIFICATION -------------------------- */

    /// @notice The independent verifier accepts a genuine deployment.
    function test_VerifyAcceptsGenuineDeployment() public {
        NVNMToken token = new NVNMToken(treasury);
        verifyScript.verify(address(token), block.chainid);
    }

    /// @notice The reconstructed runtime is exactly the deployed runtime.
    function test_ApprovedRuntimeMatchesDeployedCode() public {
        NVNMToken token = new NVNMToken(treasury);
        assertEq(verifyScript.approvedRuntime(address(token), block.chainid), address(token).code, "runtime");
    }

    /// @notice The verifier rejects an address with no code.
    function test_Revert_VerifyRejectsEmptyAddress() public {
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.Verify__Failed.selector, "no code at address"));
        verifyScript.verify(makeAddr("nothing"), block.chainid);
    }

    function test_Revert_VerifyRejectsWrongChain() public {
        NVNMToken token = new NVNMToken(treasury);
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.Verify__Failed.selector, "chainId"));
        verifyScript.verify(address(token), block.chainid + 1);
    }

    function test_Revert_VerifyRejectsUnapprovedBytecode() public {
        NVNMToken token = new NVNMToken(treasury);
        vm.etch(address(token), hex"00");
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.Verify__Failed.selector, "token bytecode"));
        verifyScript.verify(address(token), block.chainid);
    }

    /// @notice The approved runtime copied to another address is rejected:
    ///         its immutables still name the address it was constructed at.
    function test_Revert_VerifyRejectsCopiedRuntime() public {
        NVNMToken token = new NVNMToken(treasury);
        address copy = makeAddr("copy");
        vm.etch(copy, address(token).code);
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.Verify__Failed.selector, "token bytecode"));
        verifyScript.verify(copy, block.chainid);
    }

    /// @notice A token constructed on another chain is rejected: its cached
    ///         chain id and domain separator do not match the expected chain.
    function test_Revert_VerifyRejectsTokenConstructedForAnotherChain() public {
        NVNMToken token = new NVNMToken(treasury);
        uint256 otherChain = block.chainid + 1;
        vm.chainId(otherChain);
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.Verify__Failed.selector, "token bytecode"));
        verifyScript.verify(address(token), otherChain);
    }

    function test_Revert_VerifyRejectsWrongSupply() public {
        NVNMToken token = new NVNMToken(treasury);
        vm.mockCall(address(token), abi.encodeWithSelector(token.totalSupply.selector), abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.Verify__Failed.selector, "supply"));
        verifyScript.verify(address(token), block.chainid);
    }

    function test_Revert_VerifyRejectsWrongDomain() public {
        NVNMToken token = new NVNMToken(treasury);
        vm.mockCall(
            address(token), abi.encodeWithSelector(token.DOMAIN_SEPARATOR.selector), abi.encode(bytes32(uint256(1)))
        );
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.Verify__Failed.selector, "permit domain"));
        verifyScript.verify(address(token), block.chainid);
    }
}
