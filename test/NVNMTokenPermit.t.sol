// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NVNMToken} from "../src/NVNMToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title  NVNMTokenPermitTest
 * @notice EIP-2612 / EIP-712 coverage for NVNM.
 * @dev    Deliberately self-contained: the EIP-712 digest is recomputed here
 *         from the raw type strings rather than reusing a shared helper, so a
 *         mistake in the implementation's domain construction cannot be
 *         mirrored by the test that is supposed to catch it.
 */
contract NVNMTokenPermitTest is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    NVNMToken internal token;

    address internal treasury;
    address internal spender;

    address internal owner;
    uint256 internal ownerKey;

    function setUp() public {
        treasury = makeAddr("treasury");
        spender = makeAddr("spender");
        (owner, ownerKey) = makeAddrAndKey("owner");

        token = new NVNMToken(treasury);

        vm.prank(treasury);
        token.transfer(owner, 1_000e18);
    }

    /* -------------------------------- HELPERS ------------------------------- */

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("NVNM Token")), keccak256(bytes("1")), block.chainid, address(token)
            )
        );
    }

    function _digest(
        address owner_,
        address spender_,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _sign(
        uint256 key,
        address owner_,
        address spender_,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        return vm.sign(key, _digest(owner_, spender_, value, nonce, deadline));
    }

    /* ============================== DOMAIN ================================== */

    /// @notice DOMAIN_SEPARATOR is recomputed independently and must match.
    function test_DomainSeparatorIsCorrect() public view {
        assertEq(token.DOMAIN_SEPARATOR(), _domainSeparator(), "domain separator");
    }

    /// @notice ERC-5267 domain fields are as expected.
    function test_Eip712DomainFields() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();

        assertEq(fields, hex"0f", "fields");
        assertEq(name, "NVNM Token", "name");
        assertEq(version, "1", "version");
        assertEq(chainId, block.chainid, "chainId");
        assertEq(verifyingContract, address(token), "verifyingContract");
        assertEq(salt, bytes32(0), "salt");
        assertEq(extensions.length, 0, "extensions");
    }

    /* ============================== HAPPY PATH ============================== */

    /// @notice A valid permit sets the allowance, bumps the nonce and emits.
    function test_Permit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 500e18, 0, deadline);

        assertEq(token.nonces(owner), 0, "nonce starts at zero");

        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(owner, spender, 500e18);
        token.permit(owner, spender, 500e18, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), 500e18, "allowance");
        assertEq(token.nonces(owner), 1, "nonce incremented by one");

        vm.prank(spender);
        token.transferFrom(owner, spender, 500e18);
        assertEq(token.balanceOf(spender), 500e18, "spender pulled funds");
    }

    /// @notice Anyone may submit a valid signature. This is expected EIP-2612
    ///         behaviour: permit is front-runnable by design, and a third party
    ///         relaying it is the normal gasless-approval flow.
    function test_ThirdPartyCanSubmitSomeoneElsesPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);

        vm.prank(makeAddr("randomRelayer"));
        token.permit(owner, spender, 1e18, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), 1e18, "allowance set by relayer");
    }

    /// @notice A deadline exactly equal to the current timestamp is still valid.
    function test_PermitAtExactDeadlineSucceeds() public {
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), 1e18, "boundary accepted");
    }

    /// @notice Arbitrary values and deadlines round-trip.
    function testFuzz_Permit(
        uint256 value,
        uint64 offset
    ) public {
        uint256 deadline = block.timestamp + offset;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, value, 0, deadline);
        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), value, "allowance");
    }

    /* ============================== REJECTIONS ============================== */

    /// @notice An expired deadline is rejected.
    function test_Revert_ExpiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(0, 0);
    }

    /// @notice Replaying a used signature is rejected, because the nonce moved.
    function test_Revert_SignatureReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);
        token.permit(owner, spender, 1e18, deadline, v, r, s);

        // The second attempt hashes with nonce 1, so it recovers a different
        // (effectively random) signer.
        vm.expectRevert();
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(1, 1e18);
    }

    /// @notice A signature from the wrong key is rejected.
    function test_Revert_WrongSigner() public {
        (, uint256 attackerKey) = makeAddrAndKey("attacker");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(attackerKey, owner, spender, 1e18, 0, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(attackerKey), owner));
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(0, 0);
    }

    /// @notice Mutating any signed field after signing invalidates the signature.
    function test_Revert_TamperedFields() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);

        vm.expectRevert();
        token.permit(owner, spender, 2e18, deadline, v, r, s); // value
        _assertPermitState(0, 0);

        vm.expectRevert();
        token.permit(owner, makeAddr("otherSpender"), 1e18, deadline, v, r, s); // spender
        _assertPermitState(0, 0);
        assertEq(token.allowance(owner, makeAddr("otherSpender")), 0, "other spender unchanged");

        vm.expectRevert();
        token.permit(owner, spender, 1e18, deadline + 1, v, r, s); // deadline
        _assertPermitState(0, 0);
    }

    /**
     * @notice The malleable counterpart of a valid signature is rejected.
     * @dev    For any valid (v, r, s) there is an equivalent (v', r, n - s).
     *         Accepting both is a historical vulnerability class; OpenZeppelin's
     *         ECDSA rejects the upper-half-order form outright.
     */
    function test_Revert_SignatureMalleability() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);

        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 malleableS = bytes32(n - uint256(s));
        uint8 malleableV = v == 27 ? 28 : 27;

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, malleableS));
        token.permit(owner, spender, 1e18, deadline, malleableV, r, malleableS);
        _assertPermitState(0, 0);
    }

    /// @notice Nonsensical v values are rejected.
    function test_Revert_InvalidV() public {
        uint256 deadline = block.timestamp + 1 hours;
        (, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);

        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, spender, 1e18, deadline, 26, r, s);
        _assertPermitState(0, 0);
    }

    /// @notice A signature valid for one deployment is rejected by another,
    ///         because verifyingContract is bound into the domain.
    function test_Revert_CrossContractReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);

        NVNMToken other = new NVNMToken(treasury);

        vm.expectRevert();
        other.permit(owner, spender, 1e18, deadline, v, r, s);
        assertEq(other.nonces(owner), 0, "other deployment nonce unchanged");
        assertEq(other.allowance(owner, spender), 0, "other deployment allowance unchanged");
    }

    /// @notice Changing the chain id changes the domain separator, so an old
    ///         signature no longer validates. Exercises OpenZeppelin's
    ///         cached-versus-recomputed domain separator logic: the separator
    ///         cached at deployment is bypassed and rebuilt from the hashed
    ///         name and version, and a signature over the rebuilt domain works.
    function test_Revert_CrossChainReplay() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);

        bytes32 before = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != before, "domain separator must change with chain id");
        assertEq(token.DOMAIN_SEPARATOR(), _domainSeparator(), "rebuilt domain separator");

        vm.expectRevert();
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(0, 0);

        (v, r, s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(1, 1e18);
    }

    function _assertPermitState(
        uint256 nonce,
        uint256 allowance
    ) internal view {
        assertEq(token.nonces(owner), nonce, "permit nonce");
        assertEq(token.allowance(owner, spender), allowance, "permit allowance");
    }

    function test_Revert_ZeroSpenderDoesNotConsumeNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, address(0), 1e18, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 1e18, deadline, v, r, s);
        _assertPermitState(0, 0);
        assertEq(token.allowance(owner, address(0)), 0, "zero spender unchanged");
        (v, r, s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(1, 1e18);
    }

    function test_Revert_ZeroOwner() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, address(0), spender, 1e18, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, owner, address(0)));
        token.permit(address(0), spender, 1e18, deadline, v, r, s);
        assertEq(token.nonces(address(0)), 0, "zero owner nonce unchanged");
        assertEq(token.allowance(address(0), spender), 0, "zero owner allowance unchanged");
    }

    function test_Revert_FutureNonceThenValidPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerKey, owner, spender, 1e18, 1, deadline);
        vm.expectRevert();
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(0, 0);
        (v, r, s) = _sign(ownerKey, owner, spender, 1e18, 0, deadline);
        token.permit(owner, spender, 1e18, deadline, v, r, s);
        _assertPermitState(1, 1e18);
    }

    function test_Revert_AllZeroSignature() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, spender, 1e18, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        _assertPermitState(0, 0);
    }
}
