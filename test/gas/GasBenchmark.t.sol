// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NVNMToken} from "../../src/NVNMToken.sol";
import {BaselineERC20} from "./BaselineERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title  GasBenchmark
 * @notice Re-runnable gas measurements for NVNM.
 *
 *         Comparable token operations are measured against both NVNM and
 *         {BaselineERC20}, an unmodified OpenZeppelin ERC-20 without permit.
 *         Deployment, view and permit measurements also include individual
 *         values.
 *         The difference compares execution in the specified access/storage
 *         state; it is not a fixed overhead for a holder's wallet transaction.
 *
 * @dev METHODOLOGY — read this before quoting any number.
 *
 *      Call measurements use `vm.snapshotGasLastCall`, which records the gas
 *      consumed by the EVM *inside* the call frame of the most recent call, so
 *      each figure is independent of the test code around it. Paired
 *      `vm.startSnapshotGas` / `vm.stopSnapshotGas` windows are not used for
 *      calls: a later window in the same test also counts the test's own gas
 *      since the previous window closed.
 *
 *      `vm.snapshotGasLastCall` does not record contract creation, so each
 *      deployment is measured by a `vm.startSnapshotGas` window that is the
 *      only window in its test.
 *
 *      What the numbers INCLUDE:
 *        - all execution and storage costs of the call itself
 *        - EIP-2929 cold/warm access costs incurred inside the call frame
 *
 *      What the numbers EXCLUDE:
 *        - the 21,000 gas intrinsic transaction cost
 *        - calldata cost (16 gas per non-zero byte, 4 per zero byte), which for
 *          a `transfer(address,uint256)` adds roughly 400-600 gas on-chain
 *        - the caller's cost of making the call, including its access to the
 *          token account
 *        - refunds, which are settled at the end of a real transaction and are
 *          capped at a fraction of total gas used
 *
 *      Adding 21,000 and calldata does not reproduce a wallet transaction. Use
 *      transaction receipts before publishing standalone wallet costs.
 *
 *      Storage transitions dominate ERC-20 gas, so a single "transfer" number
 *      is misleading. Each transition is measured separately:
 *        - zero -> non-zero  (20,000 gas SSTORE: a recipient's first ever tokens)
 *        - non-zero -> non-zero (2,900 gas SSTORE: the common case)
 *        - non-zero -> zero  (refund-eligible: sending an entire balance)
 *
 *      TRANSFER WARM-UP. Transfer scenarios call `_warm`, which performs a
 *      zero-value transfer between the parties. It touches their balance slots
 *      without moving value. `_warm` does not access allowance slots.
 *
 *      Approval and transferFrom scenarios have their own allowance setup:
 *      first approval touches a fresh slot, whereas overwrite/revoke and
 *      transferFrom follow an approval in the same test. Views and permit also
 *      have distinct access histories. Rows are not uniformly warm or
 *      clean-storage measurements. {test_Gas_FirstVsRepeatTransfer} separately
 *      shows how access history and dirty-slot pricing affect a repeat call.
 */
contract GasBenchmarkTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;

    BaselineERC20 internal baseline;
    NVNMToken internal nvnm;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal fresh1 = makeAddr("fresh1");
    address internal fresh2 = makeAddr("fresh2");
    address internal spender = makeAddr("spender");

    function setUp() public {
        baseline = new BaselineERC20(treasury);
        nvnm = new NVNMToken(treasury);

        // Seed nonzero holder balances. Each scenario below establishes its
        // own access history before measuring.
        vm.startPrank(treasury);
        baseline.transfer(alice, 1_000_000e18);
        baseline.transfer(bob, 1_000_000e18);
        nvnm.transfer(alice, 1_000_000e18);
        nvnm.transfer(bob, 1_000_000e18);
        vm.stopPrank();
    }

    /// @dev Warms transfer-related accounts and slots without moving tokens.
    ///      Does not warm allowances; approval scenarios need separate setup.
    function _warm(
        address from,
        address to
    ) internal {
        vm.prank(from);
        baseline.transfer(to, 0);
        vm.prank(from);
        nvnm.transfer(to, 0);
    }

    /* ============================ DEPLOYMENT SIZE =========================== */

    // One test per contract: each snapshot window must be the only one in its
    // test (see the methodology note above).

    /// @notice Records the baseline's deployment cost and runtime size.
    function test_Gas_Deployment_Baseline() public {
        vm.startSnapshotGas("deploy_Baseline");
        BaselineERC20 b = new BaselineERC20(treasury);
        uint256 g = vm.stopSnapshotGas();

        _reportOne("deploy_Baseline", g);
        _reportOne("size_Baseline_runtime", address(b).code.length);
    }

    /// @notice Records NVNM's deployment cost and runtime size.
    function test_Gas_Deployment_NVNM() public {
        vm.startSnapshotGas("deploy_NVNM");
        NVNMToken t = new NVNMToken(treasury);
        uint256 g = vm.stopSnapshotGas();

        _reportOne("deploy_NVNM", g);
        _reportOne("size_NVNM_runtime", address(t).code.length);
    }

    /* ================================ TRANSFER ============================== */

    /// @notice transfer to an account that has never held tokens (0 -> non-zero).
    function test_Gas_Transfer_ToFreshAccount() public {
        // Warm the access, but leave the recipient balances at zero so the
        // 20,000-gas zero -> non-zero SSTORE is what this row measures.
        _warm(alice, fresh1);
        vm.prank(alice);
        nvnm.transfer(fresh2, 0);
        vm.prank(alice);
        baseline.transfer(fresh1, 1e18);
        uint256 g = vm.snapshotGasLastCall("transfer_toFreshAccount_Baseline");

        vm.prank(alice);
        nvnm.transfer(fresh2, 1e18);
        uint256 gp = vm.snapshotGasLastCall("transfer_toFreshAccount_NVNM");

        _report("transfer_toFreshAccount", g, gp);
    }

    /// @notice transfer to an account that already holds a balance. The common case.
    function test_Gas_Transfer_ToExistingHolder() public {
        _warm(alice, bob);
        vm.prank(alice);
        baseline.transfer(bob, 1e18);
        uint256 g = vm.snapshotGasLastCall("transfer_toExistingHolder_Baseline");

        vm.prank(alice);
        nvnm.transfer(bob, 1e18);
        uint256 gp = vm.snapshotGasLastCall("transfer_toExistingHolder_NVNM");

        _report("transfer_toExistingHolder", g, gp);
    }

    /// @notice transfer of an entire balance, zeroing the sender's slot.
    function test_Gas_Transfer_EntireBalance() public {
        _warm(alice, bob);
        // Use the funded amount directly so this scenario has no additional
        // balanceOf call beyond its explicit transfer warm-up.
        uint256 balBaseline = 1_000_000e18;
        vm.prank(alice);
        baseline.transfer(bob, balBaseline);
        uint256 g = vm.snapshotGasLastCall("transfer_entireBalance_Baseline");

        uint256 balNvnm = 1_000_000e18;
        vm.prank(alice);
        nvnm.transfer(bob, balNvnm);
        uint256 gp = vm.snapshotGasLastCall("transfer_entireBalance_NVNM");

        _report("transfer_entireBalance", g, gp);
    }

    /// @notice Zero-value transfer: the floor cost of the entrypoint.
    function test_Gas_Transfer_ZeroAmount() public {
        _warm(alice, bob);
        vm.prank(alice);
        baseline.transfer(bob, 0);
        uint256 g = vm.snapshotGasLastCall("transfer_zeroAmount_Baseline");

        vm.prank(alice);
        nvnm.transfer(bob, 0);
        uint256 gp = vm.snapshotGasLastCall("transfer_zeroAmount_NVNM");

        _report("transfer_zeroAmount", g, gp);
    }

    /* ================================ APPROVE =============================== */

    /// @notice approve 0 -> non-zero, the expensive first approval.
    function test_Gas_Approve_ZeroToNonZero() public {
        _warm(alice, spender);
        vm.prank(alice);
        baseline.approve(spender, 1e18);
        uint256 g = vm.snapshotGasLastCall("approve_zeroToNonZero_Baseline");

        vm.prank(alice);
        nvnm.approve(spender, 1e18);
        uint256 gp = vm.snapshotGasLastCall("approve_zeroToNonZero_NVNM");

        _report("approve_zeroToNonZero", g, gp);
    }

    /// @notice approve non-zero -> non-zero, an allowance top-up.
    function test_Gas_Approve_Overwrite() public {
        _warm(alice, spender);
        vm.startPrank(alice);
        baseline.approve(spender, 1e18);
        nvnm.approve(spender, 1e18);
        vm.stopPrank();

        vm.prank(alice);
        baseline.approve(spender, 2e18);
        uint256 g = vm.snapshotGasLastCall("approve_overwrite_Baseline");

        vm.prank(alice);
        nvnm.approve(spender, 2e18);
        uint256 gp = vm.snapshotGasLastCall("approve_overwrite_NVNM");

        _report("approve_overwrite", g, gp);
    }

    /// @notice approve non-zero -> 0, revoking an allowance.
    function test_Gas_Approve_Revoke() public {
        _warm(alice, spender);
        vm.startPrank(alice);
        baseline.approve(spender, 1e18);
        nvnm.approve(spender, 1e18);
        vm.stopPrank();

        vm.prank(alice);
        baseline.approve(spender, 0);
        uint256 g = vm.snapshotGasLastCall("approve_revoke_Baseline");

        vm.prank(alice);
        nvnm.approve(spender, 0);
        uint256 gp = vm.snapshotGasLastCall("approve_revoke_NVNM");

        _report("approve_revoke", g, gp);
    }

    /* ============================== TRANSFERFROM ============================ */

    /// @notice transferFrom with a finite allowance, which is decremented.
    function test_Gas_TransferFrom_FiniteAllowance() public {
        _warm(alice, bob);
        vm.startPrank(alice);
        baseline.approve(spender, 1000e18);
        nvnm.approve(spender, 1000e18);
        vm.stopPrank();

        vm.prank(spender);
        baseline.transferFrom(alice, bob, 1e18);
        uint256 g = vm.snapshotGasLastCall("transferFrom_finiteAllowance_Baseline");

        vm.prank(spender);
        nvnm.transferFrom(alice, bob, 1e18);
        uint256 gp = vm.snapshotGasLastCall("transferFrom_finiteAllowance_NVNM");

        _report("transferFrom_finiteAllowance", g, gp);
    }

    /// @notice transferFrom with an infinite allowance, which is NOT decremented
    ///         and therefore skips one SSTORE.
    function test_Gas_TransferFrom_InfiniteAllowance() public {
        _warm(alice, bob);
        vm.startPrank(alice);
        baseline.approve(spender, type(uint256).max);
        nvnm.approve(spender, type(uint256).max);
        vm.stopPrank();

        vm.prank(spender);
        baseline.transferFrom(alice, bob, 1e18);
        uint256 g = vm.snapshotGasLastCall("transferFrom_infiniteAllowance_Baseline");

        vm.prank(spender);
        nvnm.transferFrom(alice, bob, 1e18);
        uint256 gp = vm.snapshotGasLastCall("transferFrom_infiniteAllowance_NVNM");

        _report("transferFrom_infiniteAllowance", g, gp);
    }

    /**
     * @notice The premium the FIRST transfer in a transaction pays over an
     *         identical REPEAT transfer later in the same transaction.
     * @dev    This delta is not purely EIP-2929 cold access. It combines two
     *         effects and should never be quoted as one:
     *           - cold storage-slot access on the first call;
     *           - dirty-slot pricing when a repeat call rewrites balances
     *             already changed in the same transaction.
     *         Other scenarios have their own setup and are not all warm,
     *         clean-storage calls. This is not a standalone transaction quote.
     */
    function test_Gas_FirstVsRepeatTransfer() public {
        vm.prank(alice);
        nvnm.transfer(bob, 1e18);
        uint256 cold = vm.snapshotGasLastCall("transfer_first_NVNM");

        vm.prank(alice);
        nvnm.transfer(bob, 1e18);
        uint256 warm = vm.snapshotGasLastCall("transfer_repeat_NVNM");

        _reportOne("transfer_first", cold);
        _reportOne("transfer_repeat", warm);
        _reportOne("first_vs_repeat_delta", cold - warm);
    }

    /* ================================= VIEWS ================================ */

    /// @notice Read-only entrypoints on the deployed design, for integrators
    ///         budgeting static calls.
    function test_Gas_Views() public {
        nvnm.balanceOf(alice);
        uint256 g1 = vm.snapshotGasLastCall("balanceOf_NVNM");

        nvnm.totalSupply();
        uint256 g2 = vm.snapshotGasLastCall("totalSupply_NVNM");

        nvnm.allowance(alice, spender);
        uint256 g3 = vm.snapshotGasLastCall("allowance_NVNM");

        _reportOne("view_balanceOf", g1);
        _reportOne("view_totalSupply", g2);
        _reportOne("view_allowance", g3);
    }

    /* ======================= NVNM-ONLY OPERATIONS =========================== */

    /// @notice An owner's first permit: the nonce and the allowance both move
    ///         from zero to non-zero. The baseline ERC-20 has no permit.
    function test_Gas_Permit() public {
        (address owner, uint256 key) = makeAddrAndKey("permitOwner");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                1e18,
                0,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", nvnm.DOMAIN_SEPARATOR(), structHash)));

        nvnm.permit(owner, spender, 1e18, deadline, v, r, s);
        uint256 gp = vm.snapshotGasLastCall("permit_NVNM");

        _reportOne("permit", gp);
    }

    /* ================================ HELPERS =============================== */

    /// @dev Emits a comparable row: baseline cost, NVNM cost. The generator
    ///      derives the absolute and relative overhead from the pair.
    function _report(
        string memory label,
        uint256 baselineGas,
        uint256 nvnmGas
    ) internal pure {
        // Machine-readable single line consumed by script/gas-report.mjs.
        console2.log(string.concat("GASROW|", label, "|", vm.toString(baselineGas), "|", vm.toString(nvnmGas)));
    }

    /// @dev Emits a single-value row (no baseline/NVNM pair).
    function _reportOne(
        string memory label,
        uint256 value
    ) internal pure {
        console2.log(string.concat("GASONE|", label, "|", vm.toString(value)));
    }
}
