// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AUDIT PROBE (Forge independent test-audit, 2026-06-11) — demonstrates that the fuzz/invariant
// suites never exercise the fee-on-transfer custody claim. Kept in the shipped suite as a
// regression test; the full finding/fix cycle is documented in /TEST_AUDIT.md.
// Run: forge test --match-path test/CommitStakeFeeTokenProbe.t.sol

import {Test} from "forge-std/Test.sol";
import {CommitStake, IERC20} from "../src/CommitStake.sol";
import {FeeToken} from "./mocks/AttackTokens.sol";

/// Re-runs the SAME ghost-conservation model the production invariant uses, but with a 10%
/// fee-on-transfer token instead of the 1:1 MockERC20. Proves two things:
///   (A) the production invariant's ghost ledger is hardcoded 1:1 — it breaks the instant a
///       non-1:1 token is used, so it can never validate the contracts' "safe against any
///       non-standard ERC-20" NatSpec claim;
///   (B) the contract itself stays solvent BY ITS OWN BOOKS even under a fee token (no stuck
///       funds, no double pay) — so the claim is a *test/doc* gap, not an Arc exploit.
contract CommitStakeFeeTokenProbe is Test {
    CommitStake cs;
    FeeToken fee;

    address staker = address(0xA1);
    address verifier = address(0xF1);
    address beneficiary = address(0xBE1);

    function setUp() public {
        fee = new FeeToken(1000); // 10% skim on every transfer
        cs = new CommitStake(IERC20(address(fee)));
        fee.mint(staker, 1_000_000e6);
        vm.prank(staker);
        fee.approve(address(cs), type(uint256).max);
        vm.warp(1_000_000);
    }

    /// (A) The production invariant_solvent_flowConservation models payout as "amount the
    /// recipient received == amount the escrow released". Under a fee token that is false: a
    /// fail-resolution pushes c.amount out of escrow, the beneficiary nets only 90% of it, and the
    /// ghost "still owed" figure no longer matches the (zero) escrow balance. This is exactly the
    /// assertion the shipped suite makes — and it would FAIL here, which is why the suite can only
    /// ever be run against a 1:1 mock.
    function test_ghostFlowModel_breaksUnderFeeToken() public {
        uint256 amt = 100_000e6;
        uint256 escrowBefore = fee.balanceOf(address(cs));
        vm.prank(staker);
        uint256 id = cs.create(verifier, beneficiary, amt, uint64(block.timestamp + 1 days), "g");
        uint256 amountIn = fee.balanceOf(address(cs)) - escrowBefore; // ghost: real delta in

        uint256 benBefore = fee.balanceOf(beneficiary);
        vm.prank(verifier);
        cs.resolve(id, false); // slash to beneficiary
        uint256 beneficiaryPaid = fee.balanceOf(beneficiary) - benBefore; // ghost: real delta out

        uint256 ghostStillOwed = amountIn - beneficiaryPaid;
        // The production invariant asserts escrow balance == ghostStillOwed. Show it does NOT hold:
        assertTrue(
            fee.balanceOf(address(cs)) != ghostStillOwed,
            "if this holds, the fee token was 1:1 after all"
        );
        // The fee skimmed on the way OUT is the entire mismatch.
        assertEq(ghostStillOwed, (amountIn * 1000) / 10_000, "mismatch == outbound fee");
    }

    /// (B) Fairness check: by the contract's OWN books it is still perfectly solvent under the fee
    /// token — escrow holds exactly what it still owes on active commitments, and a terminal
    /// commitment leaves nothing stuck. So the contract is safe on Arc; the gap is that the suite
    /// never proves the headline claim.
    function test_contractStaysSolventByOwnBooks_underFeeToken() public {
        uint256 amt = 100_000e6;
        vm.prank(staker);
        uint256 id = cs.create(verifier, beneficiary, amt, uint64(block.timestamp + 1 days), "g");
        // escrow == the amount it booked (received), which is what it still owes
        assertEq(fee.balanceOf(address(cs)), cs.get(id).amount, "escrow != own-book liability");
        vm.prank(verifier);
        cs.resolve(id, false);
        assertEq(fee.balanceOf(address(cs)), 0, "funds stuck after terminal slash");
    }
}
