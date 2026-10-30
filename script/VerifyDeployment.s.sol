// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NVNMToken} from "../src/NVNMToken.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title  VerifyDeployment
 * @author NVNM Foundation Limited
 * @notice Checks a deployed token against a reviewed local build and an explicit chain.
 * @dev Build the approved release into out/ first. The token address and chain must
 *      come from the reviewed deployment record, never from observed chain state.
 *      This certifies runtime build identity, metadata, supply and the permit domain.
 *      It cannot show which constructor ran; finalizing the deployment record with
 *      script/deployment-manifest.mjs checks the creation transaction itself.
 */
contract VerifyDeployment is Script {
    error Verify__Failed(string what);

    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    string internal constant NAME = "NVNM Token";
    string internal constant VERSION = "1";
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Every immutable in the approved build is declared by this source.
    string internal constant EIP712_SOURCE = "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
    uint256 internal constant IMMUTABLE_COUNT = 7;

    // JSON object keys are ABI-encoded alphabetically by parseJson.
    struct ImmutableReference {
        uint256 length;
        uint256 start;
    }

    /// @dev An immutable as declared in the approved EIP712 source.
    struct ImmutableDeclaration {
        uint256 id;
        string name;
        string typeString;
    }

    /// @notice Verifies the configured address. Both inputs are mandatory.
    function run() external view {
        verify(vm.envAddress("NVNM_TOKEN_ADDRESS"), vm.envUint("EXPECTED_CHAIN_ID"));
    }

    /// @notice Checks exact code, metadata, supply and permit domain.
    /// @param token   The token address from the reviewed deployment record.
    /// @param chainId The chain the token was deployed on, from the same record.
    function verify(
        address token,
        uint256 chainId
    ) public view {
        if (block.chainid != chainId || chainId == 0) revert Verify__Failed("chainId");
        if (token.code.length == 0) revert Verify__Failed("no code at address");
        if (token.codehash != keccak256(approvedRuntime(token, chainId))) revert Verify__Failed("token bytecode");

        NVNMToken t = NVNMToken(token);
        if (keccak256(bytes(t.name())) != keccak256(bytes(NAME))) revert Verify__Failed("name");
        if (keccak256(bytes(t.symbol())) != keccak256("NVNM")) revert Verify__Failed("symbol");
        if (t.decimals() != 18) revert Verify__Failed("decimals");
        if (t.totalSupply() != EXPECTED_SUPPLY || t.INITIAL_SUPPLY() != EXPECTED_SUPPLY) {
            revert Verify__Failed("supply");
        }
        if (t.DOMAIN_SEPARATOR() != _domainSeparator(token, chainId)) revert Verify__Failed("permit domain");
        _checkDomainFields(t, chainId);
        console2.log("Verified approved build and expected configuration at", token);
        console2.log("Chain", chainId);
    }

    function _checkDomainFields(
        NVNMToken t,
        uint256 chainId
    ) internal view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 domainChainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = t.eip712Domain();
        if (
            fields != hex"0f" || keccak256(bytes(name)) != keccak256(bytes(NAME))
                || keccak256(bytes(version)) != keccak256(bytes(VERSION)) || domainChainId != chainId
                || verifyingContract != address(t) || salt != bytes32(0) || extensions.length != 0
        ) revert Verify__Failed("permit domain fields");
    }

    function _domainSeparator(
        address token,
        uint256 chainId
    ) internal pure returns (bytes32) {
        bytes32 hashedName = keccak256(bytes(NAME));
        return keccak256(abi.encode(DOMAIN_TYPEHASH, hashedName, keccak256(bytes(VERSION)), chainId, token));
    }

    /**
     * @notice The approved build's runtime code as it must appear at `token` on `chainId`.
     * @dev The artifact holds zeroed placeholders where the constructor writes
     *      immutables. NVNM's only immutables are the seven OpenZeppelin's EIP712
     *      declares, and each value is fixed by the token address and chain: the
     *      cached domain separator, chain id and address, and the hashed and
     *      short-string name and version. Placeholders are identified by their
     *      compiler-assigned declarations in EIP712's AST, never by position.
     *      Reject missing or additional immutables, nonzero templates and
     *      overlapping references. A future build with other immutables needs an
     *      explicitly reviewed resolver; it must not silently weaken this check.
     * @param  token   The address the token was constructed at.
     * @param  chainId The chain the token was constructed on.
     * @return runtime The exact runtime code the approved constructor leaves at `token`.
     */
    function approvedRuntime(
        address token,
        uint256 chainId
    ) public view returns (bytes memory runtime) {
        string memory artifact = vm.readFile(string.concat(vm.projectRoot(), "/out/NVNMToken.sol/NVNMToken.json"));
        runtime = vm.parseJsonBytes(artifact, ".deployedBytecode.object");
        string[] memory keys = vm.parseJsonKeys(artifact, ".deployedBytecode.immutableReferences");
        if (keys.length != IMMUTABLE_COUNT) revert Verify__Failed("unexpected immutable declarations");

        ImmutableDeclaration[] memory declarations = _eip712Immutables();
        bytes memory covered = new bytes(runtime.length);
        uint256 resolved = 0;
        for (uint256 i; i < keys.length; ++i) {
            uint256 index = _declarationIndex(declarations, vm.parseUint(keys[i]));
            if (resolved & (1 << index) != 0) revert Verify__Failed("duplicate immutable declaration");
            resolved |= 1 << index;
            _fill(
                runtime,
                covered,
                abi.decode(
                    vm.parseJson(artifact, string.concat(".deployedBytecode.immutableReferences.", keys[i])),
                    (ImmutableReference[])
                ),
                _immutableValue(declarations[index], token, chainId)
            );
        }
    }

    /// @dev Writes `value` into each 32-byte placeholder in `refs`, refusing a
    ///      malformed, overlapping or nonzero placeholder.
    function _fill(
        bytes memory runtime,
        bytes memory covered,
        ImmutableReference[] memory refs,
        bytes32 value
    ) internal pure {
        if (refs.length == 0) revert Verify__Failed("missing immutable reference");
        for (uint256 i; i < refs.length; ++i) {
            uint256 start = refs[i].start;
            if (refs[i].length != 32 || start + 32 > runtime.length) {
                revert Verify__Failed("invalid immutable reference");
            }
            for (uint256 k = start; k < start + 32; ++k) {
                if (covered[k] != 0) revert Verify__Failed("overlapping immutable reference");
                if (runtime[k] != 0) revert Verify__Failed("nonzero immutable template");
                covered[k] = 0x01;
            }
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                mstore(add(add(runtime, 32), start), value)
            }
        }
    }

    /// @dev Lists the immutable declarations in the approved EIP712 source.
    function _eip712Immutables() internal view returns (ImmutableDeclaration[] memory declarations) {
        string memory ast = vm.readFile(string.concat(vm.projectRoot(), "/out/EIP712.sol/EIP712.json"));
        if (keccak256(bytes(vm.parseJsonString(ast, ".ast.absolutePath"))) != keccak256(bytes(EIP712_SOURCE))) {
            revert Verify__Failed("unexpected EIP712 artifact");
        }
        declarations = new ImmutableDeclaration[](IMMUTABLE_COUNT);
        uint256 found = 0;
        string[] memory kinds = abi.decode(vm.parseJson(ast, ".ast.nodes[*].nodeType"), (string[]));
        for (uint256 i; i < kinds.length; ++i) {
            if (keccak256(bytes(kinds[i])) != keccak256("ContractDefinition")) continue;
            string memory base = string.concat(".ast.nodes[", vm.toString(i), "]");
            string[] memory members =
                abi.decode(vm.parseJson(ast, string.concat(base, ".nodes[*].nodeType")), (string[]));
            for (uint256 j; j < members.length; ++j) {
                if (keccak256(bytes(members[j])) != keccak256("VariableDeclaration")) continue;
                string memory field = string.concat(base, ".nodes[", vm.toString(j), "]");
                if (
                    keccak256(bytes(vm.parseJsonString(ast, string.concat(field, ".mutability"))))
                        != keccak256("immutable")
                ) {
                    continue;
                }
                if (found == IMMUTABLE_COUNT) revert Verify__Failed("unexpected EIP712 immutables");
                declarations[found] = ImmutableDeclaration({
                    id: vm.parseJsonUint(ast, string.concat(field, ".id")),
                    name: vm.parseJsonString(ast, string.concat(field, ".name")),
                    typeString: vm.parseJsonString(ast, string.concat(field, ".typeDescriptions.typeString"))
                });
                ++found;
            }
        }
        if (found != IMMUTABLE_COUNT) revert Verify__Failed("unexpected EIP712 immutables");
    }

    function _declarationIndex(
        ImmutableDeclaration[] memory declarations,
        uint256 id
    ) internal pure returns (uint256) {
        for (uint256 i; i < declarations.length; ++i) {
            if (declarations[i].id == id) return i;
        }
        revert Verify__Failed("immutable outside EIP712");
    }

    /// @dev The value the approved constructor writes for each EIP712 immutable.
    function _immutableValue(
        ImmutableDeclaration memory declaration,
        address token,
        uint256 chainId
    ) internal pure returns (bytes32) {
        bytes32 n = keccak256(bytes(declaration.name));
        bytes32 t = keccak256(bytes(declaration.typeString));
        if (n == keccak256("_cachedDomainSeparator") && t == keccak256("bytes32")) {
            return _domainSeparator(token, chainId);
        }
        if (n == keccak256("_cachedChainId") && t == keccak256("uint256")) return bytes32(chainId);
        if (n == keccak256("_cachedThis") && t == keccak256("address")) return bytes32(uint256(uint160(token)));
        if (n == keccak256("_hashedName") && t == keccak256("bytes32")) return keccak256(bytes(NAME));
        if (n == keccak256("_hashedVersion") && t == keccak256("bytes32")) return keccak256(bytes(VERSION));
        if (n == keccak256("_name") && t == keccak256("ShortString")) return _shortString(NAME);
        if (n == keccak256("_version") && t == keccak256("ShortString")) return _shortString(VERSION);
        revert Verify__Failed("unexpected immutable");
    }

    /// @dev OpenZeppelin's ShortString encoding: bytes left-aligned, length in the last byte.
    function _shortString(
        string memory value
    ) internal pure returns (bytes32) {
        return bytes32(uint256(bytes32(bytes(value))) | bytes(value).length);
    }
}
