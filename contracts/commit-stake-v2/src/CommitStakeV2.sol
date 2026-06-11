// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 surface used by CommitStakeV2 (Arc USDC is ERC-20 + the gas token).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice The AgentBond surface CommitStakeV2 drives as an enforcer. ABI-compatible with
///         `agent-bond/src/AgentBond.sol` (enums encode as uint8).
interface IAgentBond {
    enum ObligationStatus {
        None,
        Active,
        Released,
        Slashed
    }

    struct Obligation {
        address agent;
        address enforcer;
        address creditor;
        uint256 amount;
        uint64 deadline;
        ObligationStatus status;
    }

    function lock(address agent, address creditor, uint256 amount, uint64 deadline)
        external
        returns (uint256 id);
    function release(uint256 id) external;
    function slash(uint256 id) external;
    function getObligation(uint256 id) external view returns (Obligation memory);
    function freeBondOf(address agent) external view returns (uint256);
}

/// @notice The real StreamPay surface (`stream-pay/src/StreamPay.sol`) CommitStakeV2 drives for
///         the verifier fee. CommitStakeV2 opens the fee stream ITSELF (it is the stream
///         `sender`, funded by the staker) because StreamPay's `cancel` is sender/recipient-only
///         — that sender-right is what makes the §7 atomic cancel on the slash branches, and the
///         on-chain read of the fee actually accrued to the verifier, possible at all.
interface IStreamPay {
    enum StreamStatus {
        None,
        Active,
        Ended
    }

    struct Stream {
        address sender;
        address recipient;
        uint256 deposit;
        uint256 withdrawn;
        uint64 start;
        uint64 stop;
        StreamStatus status;
    }

    function createStream(
        address recipient,
        uint256 deposit,
        uint64 start,
        uint64 stop,
        string calldata memo
    ) external returns (uint256 id);
    function cancel(uint256 id) external;
    function get(uint256 id) external view returns (Stream memory);
}

/// @dev Single-slot reentrancy guard (no external dependency).
abstract contract ReentrancyGuard {
    uint256 private _status;

    constructor() {
        _status = 1;
    }

    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

/// @title CommitStakeV2 — commitment escrow with an accountable (bonded) verifier
/// @notice v1 made the *staker* accountable; the verifier was trusted and unaccountable — it
///         could stay silent or lie at no cost. v2 closes that gap by reusing the stack's two
///         existing primitives instead of inventing new trust machinery:
///
///         - **AgentBond (enforcer pattern):** at `create`, a slice of the verifier's posted
///           bond is locked behind the commitment (`lock`, creditor = this contract). On a
///           clean outcome the slice is `release`d; on a liveness failure or an overturned
///           false verdict it is `slash`ed to this contract and routed by the §7a rule: the
///           wronged party receives only `damage`, the surplus is BURNED. CommitStakeV2 writes
///           zero new custody/slashing logic — it drives AgentBond's audited lifecycle.
///         - **StreamPay (fee gating):** the verifier's fee is a stream this contract opens at
///           `create` (sender = this contract, funded by the staker). Accrual gating is
///           *timing-based* (the stream must start at or after the latest possible
///           challenge-window close); on a slash branch the stream is cancelled ATOMICALLY in
///           the same transaction — holding the sender-right is what makes that possible.
///
///         The verifier's two failure modes are handled by exactly the mechanism each supports:
///
///         - **Liveness (provable on-chain):** silence past the deadline slashes the verifier's
///           slice: the staker receives `damage` (the fee actually accrued to the no-show
///           verifier; the arbiter cost is zero on this branch), the surplus is burned, and the
///           stake is returned to the staker. Trustless.
///         - **Correctness (NOT provable on-chain):** a resolved verdict opens a challenge
///           window. Only the party harmed by *this* verdict may challenge, posting a bond.
///           The dispute routes to a single arbiter named at `create` — the explicit,
///           pre-agreed root of trust. The arbiter is paid a fixed fee out of the challenge
///           bond on BOTH rulings (the fact of ruling pays, not the direction); its silence
///           fails closed (verdict stands, bond returned, arbiter unpaid). The arbiter is NOT
///           bonded or slashed by this contract, and it never sets a damage number — it rules
///           pass/fail only.
///
///         **§7a deterministic slash routing (the anti-raid core):** on every slash,
///
///             damage  =  feeAccruedToLyingVerifier  +  challengerArbiterFeeCost
///
///         where `feeAccruedToLyingVerifier` is read from StreamPay's own on-chain state at the
///         moment of the slash (NEVER a caller-supplied number — a caller value would let the
///         lying party or the challenger inject a fake damage), and the challenger's arbiter
///         fee cost is the fee actually carved from its bond. The wronged party receives only
///         `damage`; the surplus `slice − damage` is transferred to the burn address
///         (`0x…dEaD`) — deterministic and owned by no one, never a treasury. This collapses
///         the staker≡beneficiary raid's upside from the whole slice to ≈ pennies, making the
///         attack deeply −EV at any plausible arbiter error rate.
///
///         **No stake, fee, or bond leaves the escrow before a terminal transition**
///         (`finalize`, an arbiter ruling, or the liveness slash). Payouts are pushed at the
///         terminal step; there is no separate claim step.
///
///         Sizing rules enforced at `create` (the economic core):
///
///             verifierSlice  >  stake + maxAccruableFee + arbiterFee   (lying is a net loss,
///                                                              AND the §7a surplus is always
///                                                              positive: damage < slice)
///             arbiterFee + 10%×slice  <=  challengeBond  <=  arbiterFee + 25%×slice
///                                                              (§7a post-burn band: the bond
///                                                              covers the arbiter fee plus a
///                                                              small spam margin — sized to the
///                                                              post-burn prize (≈ damage), so a
///                                                              legitimate harmed party is never
///                                                              priced out of challenging)
///
///         The contract holds no admin keys, has no owner, and never custodies funds beyond the
///         individual escrows (stake + posted challenge bonds; a slashed slice and a cancelled
///         fee stream's remainder only transit within a single transaction, except a fee
///         remainder refunded early by a recipient-side cancel, which is held and forwarded to
///         the staker at the terminal step). Balance-delta accounting throughout: payouts route
///         what actually arrived, never what was requested. The production token is Arc USDC
///         (6 decimals, standard 1:1 ERC-20); all amounts are micro-USDC. Fee-on-transfer and
///         no-return tokens are tolerated for solvency, other exotic ERC-20 behaviours are out
///         of scope.
contract CommitStakeV2 is ReentrancyGuard {
    enum Status {
        None, // 0 - never created
        Active, // 1 - stake escrowed, verifier slice locked, awaiting resolve
        Resolved, // 2 - verdict recorded, challenge window open; nothing has been paid out
        Challenged, // 3 - harmed party posted a bond, awaiting the arbiter
        Finalized, // 4 - terminal: payouts ran (clean / upheld / overturned / arbiter silence)
        Expired // 5 - terminal: liveness slash ran (verifier silent past the deadline)
    }

    /// @notice Which terminal branch a commitment took. `None` until a terminal transition.
    enum Outcome {
        None, // 0 - not terminal yet
        CleanPass, // 1 - pass verdict, window closed unchallenged -> stake to staker
        CleanFail, // 2 - fail verdict, window closed unchallenged -> stake to beneficiary
        UpheldPass, // 3 - pass verdict challenged, arbiter upheld -> challenger bond slashed
        UpheldFail, // 4 - fail verdict challenged, arbiter upheld -> challenger bond slashed
        OverturnedToPass, // 5 - false fail overturned -> stake to staker; damage to staker, surplus burned
        OverturnedToFail, // 6 - false pass overturned -> stake to beneficiary; damage to beneficiary, surplus burned
        SilencePass, // 7 - pass challenged, arbiter silent -> fails closed, bond returned
        SilenceFail, // 8 - fail challenged, arbiter silent -> fails closed, bond returned
        LivenessSlash // 9 - verifier never resolved -> stake returned + damage to staker, surplus burned
    }

    struct Commitment {
        address staker; // locked the stake; harmed by a false fail
        address verifier; // bonded judge; resolves pass/fail before the deadline
        address beneficiary; // receives the stake on a (final) fail; harmed by a false pass
        address arbiter; // named root of trust for disputes; unbonded, paid per ruling
        uint256 amount; // stake actually escrowed (balance delta), micro-USDC
        uint256 verifierSlice; // AgentBond slice locked behind this commitment
        uint256 bondObligationId; // AgentBond obligation holding the slice
        uint256 challengeBond; // bond a challenger must post (create-parameter, §7a band)
        uint256 challengeBondPaid; // bond actually escrowed at challenge (balance delta)
        uint256 arbiterFee; // fixed fee paid to the arbiter out of the bond on both rulings
        uint256 feeStreamId; // StreamPay fee stream opened BY this contract at create (0 = none)
        uint64 deadline; // verifier must resolve on or before this (unix seconds)
        uint64 challengeWindow; // seconds after resolve during which a challenge is allowed
        uint64 arbiterDeadline; // seconds after challenge the arbiter has to rule
        uint64 resolvedAt; // when resolve happened (0 until then)
        uint64 challengedAt; // when challenge happened (0 until then)
        bool resolvedPass; // the verifier's verdict (meaningful once Resolved)
        Status status;
        Outcome outcome;
    }

    /// @dev `create` takes a struct to stay within stack limits; field order mirrors the spec's
    ///      interface sketch (VERIFIER_ECONOMICS.md appendix) with the arbiter fee and the fee
    ///      stream parameters added. The fee stream is OPENED BY THIS CONTRACT (it must hold
    ///      the StreamPay sender-right to cancel atomically on a slash), funded by the staker.
    struct CreateParams {
        address verifier;
        address beneficiary;
        address arbiter;
        uint256 amount; // stake to lock, micro-USDC
        uint256 verifierSlice; // AgentBond slice to lock; must exceed amount + max fee
        uint64 deadline; // unix seconds the verifier must resolve by
        uint64 challengeWindow; // seconds; must be > 0 (the window always exists)
        uint256 challengeBond; // micro-USDC a challenger must post; §7a post-burn band
        uint64 arbiterDeadline; // seconds; must be > 0
        uint256 arbiterFee; // micro-USDC paid to the arbiter from the bond on both rulings
        uint256 feeDeposit; // verifier fee budget, pulled from the staker (0 = no fee stream)
        uint64 feeStart; // unix seconds fee accrual begins; >= deadline + challengeWindow
        uint64 feeStop; // unix seconds fee accrual completes (StreamPay enforces > start)
        string goal; // human-readable description (emitted only, not stored)
    }

    /// @notice §7a surplus sink: a slashed slice's surplus above `damage` is burned here —
    ///         deterministic and owned by no one. A treasury would imply a recipient and a
    ///         decision-maker, breaking the ownerless/no-admin-keys thesis.
    address public constant BURN_ADDR = 0x000000000000000000000000000000000000dEaD;

    /// @notice §7a post-burn challenge-bond band, expressed on the SLICE (not the stake):
    ///         challengeBond ∈ [arbiterFee + 10%×slice, arbiterFee + 25%×slice].
    ///         The spam margin is sized against the post-burn capturable prize (`damage`,
    ///         ≈ pennies), NOT against the stake or the slice itself — the spec's corrected
    ///         bound. The old 25%-of-stake floor is explicitly marked wrong in the spec: it
    ///         priced the legitimate harmed party out of challenging. The cap enforces the
    ///         spec's `spamMargin <= 0.1–0.25 × slice` upper constraint so an over-sized bond
    ///         can never be used to price out the (non-consenting) beneficiary either.
    uint256 public constant SPAM_MARGIN_MIN_BPS = 1_000; // 10% of the slice
    uint256 public constant SPAM_MARGIN_MAX_BPS = 2_500; // 25% of the slice
    uint256 public constant BPS_DENOM = 10_000;

    /// @notice Recommended default slice: 150% of the stake (covers the sizing inequality
    ///         whenever the fee budget is below 50% of the stake). Informational — the enforced
    ///         rule is the strict inequality `verifierSlice > amount + maxAccruableFee`.
    uint256 public constant DEFAULT_SLICE_BPS = 15_000;

    /// @notice Buffer added to the AgentBond obligation deadline beyond the latest possible
    ///         terminal transition. The AgentBond deadline is only a backstop: if this contract
    ///         were abandoned, the verifier could eventually self-`release` and not be held
    ///         hostage. In the normal flow CommitStakeV2 always resolves the obligation first.
    uint64 public constant BOND_DEADLINE_BUFFER = 7 days;

    IERC20 public immutable usdc;
    IAgentBond public immutable agentBond;
    IStreamPay public immutable streamPay;

    uint256 public nextId = 1;
    /// @notice Sum of booked, still-owed escrow (received stakes + posted challenge bonds of
    ///         live commitments). Anything the contract holds ABOVE this is unbooked inflow —
    ///         e.g. a fee-stream remainder refunded by a recipient-side early cancel — and only
    ///         that surplus may ever be forwarded as a fee residue, so a residue payout can
    ///         never dip into another commitment's escrow.
    uint256 public totalEscrowed;
    /// @dev Not public: the auto-generated flat-tuple getter for a struct this wide does not
    ///      compile (stack depth). Read through `get(id)` instead.
    mapping(uint256 => Commitment) internal commitments;

    event Created(
        uint256 indexed id,
        address indexed staker,
        address indexed verifier,
        uint256 amount,
        uint256 verifierSlice,
        uint256 bondObligationId,
        string goal
    );
    event Resolved(uint256 indexed id, bool passed, uint64 challengeWindowEndsAt);
    event Challenged(uint256 indexed id, address indexed challenger, uint256 bondPaid, uint64 arbiterDeadlineAt);
    event Ruled(uint256 indexed id, address indexed arbiter, bool overturned);
    event Finalized(uint256 indexed id, Outcome outcome);
    event StakeRouted(uint256 indexed id, address indexed to, uint256 amount);
    event SliceRouted(uint256 indexed id, address indexed to, uint256 amount);
    event ChallengeBondRouted(uint256 indexed id, address indexed to, uint256 amount);
    /// @dev Emitted whenever a registered fee stream is settled at a terminal step:
    ///      `feeAccrued` is the total the verifier actually received (read from StreamPay state,
    ///      the on-chain damage input), `refundedToStaker` the unstreamed remainder returned.
    event FeeStreamSettled(uint256 indexed id, uint256 feeAccrued, uint256 refundedToStaker);

    constructor(IERC20 _usdc, IAgentBond _agentBond, IStreamPay _streamPay) {
        require(address(_usdc) != address(0), "USDC_ZERO");
        require(address(_agentBond) != address(0), "AGENT_BOND_ZERO");
        require(address(_streamPay) != address(0), "STREAM_PAY_ZERO");
        usdc = _usdc;
        agentBond = _agentBond;
        streamPay = _streamPay;
    }

    // --- lifecycle ---

    /// @notice Lock `p.amount` USDC behind a new commitment and lock `p.verifierSlice` of the
    ///         verifier's AgentBond bond behind it. The caller (staker) must `approve` this
    ///         contract for `p.amount` (+ `p.feeDeposit` if a fee stream is requested) on USDC
    ///         first; the verifier must have granted this contract slashing allowance on
    ///         AgentBond (`setSlashAllowance`) and hold enough free bond — AgentBond reverts the
    ///         lock otherwise, so a verifier can never take on more commitments than its posted
    ///         bond covers.
    ///
    ///         Enforced at create (all spec-decided):
    ///         - conflict-of-interest: the arbiter is none of verifier / staker / beneficiary;
    ///         - sizing: `verifierSlice > amount + maxAccruableFee + arbiterFee` (strict), where
    ///           the max accruable fee is the fee deposit (0 if none); folding in `arbiterFee`
    ///           keeps the §7a `damage` term strictly below the slice on every slash branch, so
    ///           the surplus burned is always positive (gate-4 HIGH fix);
    ///         - §7a post-burn challenge-bond band:
    ///           `arbiterFee + 10%×slice <= challengeBond <= arbiterFee + 25%×slice`;
    ///         - the challenge window and arbiter deadline always exist (> 0);
    ///         - a requested fee stream must not start accruing before the latest possible
    ///           challenge-window close (`deadline + challengeWindow`) — the §7 timing gate.
    ///           Accrual during a late arbiter path remains possible; that residue is exactly
    ///           what the sizing inequality absorbs.
    ///
    ///         If a fee is requested, this contract pulls `feeDeposit` from the staker and opens
    ///         the StreamPay stream ITSELF (sender = this contract, recipient = verifier). The
    ///         sender-right is what lets the slash branches cancel the stream atomically and
    ///         read the verifier's actually-accrued fee from on-chain state (§7, §7a).
    function create(CreateParams calldata p) external nonReentrant returns (uint256 id) {
        require(p.amount > 0, "AMOUNT_ZERO");
        require(p.verifier != address(0), "VERIFIER_ZERO");
        require(p.beneficiary != address(0), "BENEFICIARY_ZERO");
        require(p.arbiter != address(0), "ARBITER_ZERO");
        // Conflict-of-interest, enforced in code (spec §6): the dispute judge must be none of
        // the three parties whose money it would rule over.
        require(p.arbiter != p.verifier, "ARBITER_IS_VERIFIER");
        require(p.arbiter != msg.sender, "ARBITER_IS_STAKER");
        require(p.arbiter != p.beneficiary, "ARBITER_IS_BENEFICIARY");
        require(p.deadline > block.timestamp, "DEADLINE_PAST");
        require(p.challengeWindow > 0, "WINDOW_ZERO");
        require(p.arbiterDeadline > 0, "ARBITER_DEADLINE_ZERO");
        // Minimum slice for a SATISFIABLE bond band: below 4 micro-USDC the round-up floor
        // (ceil 10% × slice) exceeds the round-down cap (floor 25% × slice), leaving no legal
        // `challengeBond` and reverting with an inscrutable BOND_BELOW_FLOOR/ABOVE_CAP pair.
        // A clean explicit error instead. (LOW finding, gate-4 cold audit.) The sizing rule below
        // independently forces a far larger slice for any non-dust commitment.
        require(p.verifierSlice >= 4, "SLICE_TOO_SMALL_FOR_BOND_BAND");
        // §7a post-burn band: the bond covers the arbiter fee plus a small spam margin sized on
        // the slice. Floor: a frivolous challenge always costs more than the post-burn prize
        // (damage ≈ pennies). Cap: a legitimate harmed party is never priced out of challenging.
        require(
            p.challengeBond >= challengeBondFloor(p.verifierSlice, p.arbiterFee),
            "BOND_BELOW_FLOOR"
        );
        require(
            p.challengeBond <= challengeBondCap(p.verifierSlice, p.arbiterFee), "BOND_ABOVE_CAP"
        );

        // Max fee the verifier could ever accrue: the full fee deposit. Timing gate (§7): the
        // stream may not start accruing before the latest possible unchallenged finalize.
        // Wall-clock gating, not a hard condition — see sizing.
        if (p.feeDeposit != 0) {
            require(
                p.feeStart >= uint256(p.deadline) + p.challengeWindow, "FEE_STREAM_STARTS_EARLY"
            );
        }
        // The central formula: a lie must be a mathematical loss in every outcome. The slice must
        // strictly exceed everything the §7a `damage` term can ever reach — stake + the full fee
        // deposit (max accruable fee) + the arbiter fee — so that on every slash branch
        // `damage = feeAccrued + min(arbiterFee, bond) <= feeDeposit + arbiterFee < slice`, which
        // makes the surplus `slice - toHarmed` STRICTLY POSITIVE by construction and the §7a burn
        // a real guarantee. Folding `arbiterFee` in (gate-4 HIGH fix) is what closes the
        // colluding-arbiter slice-recapture: damage can no longer reach the slice. This strict
        // inequality subsumes the old `slice > amount + feeDeposit` rule.
        require(
            p.verifierSlice > p.amount + p.feeDeposit + p.arbiterFee, "SLICE_TOO_SMALL"
        );

        id = nextId++;

        // Balance-delta accounting: book what actually arrived, so payouts never exceed what
        // the escrow received.
        uint256 balBefore = usdc.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), p.amount);
        uint256 received = usdc.balanceOf(address(this)) - balBefore;
        require(received > 0, "NO_FUNDS");
        totalEscrowed += received;

        // Open the verifier-fee stream with this contract as the sender, funded by the staker.
        uint256 feeStreamId = 0;
        if (p.feeDeposit != 0) {
            uint256 feeBalBefore = usdc.balanceOf(address(this));
            _safeTransferFrom(msg.sender, address(this), p.feeDeposit);
            uint256 feeReceived = usdc.balanceOf(address(this)) - feeBalBefore;
            require(feeReceived > 0, "NO_FEE_FUNDS");
            _safeApprove(address(streamPay), feeReceived);
            feeStreamId = streamPay.createStream(
                p.verifier, feeReceived, p.feeStart, p.feeStop, "CommitStakeV2 verifier fee"
            );
        }

        // Lock the verifier's slice. creditor = address(this): the wronged party is not known
        // at lock time (a false fail harms the staker, a false pass the beneficiary), so this
        // contract takes custody of a slashed slice and routes it at the terminal step.
        // The obligation deadline is the latest possible terminal transition plus a buffer —
        // a backstop against this contract being abandoned, never hit in the normal flow.
        uint256 obligationId = agentBond.lock(
            p.verifier,
            address(this),
            p.verifierSlice,
            p.deadline + p.challengeWindow + p.arbiterDeadline + BOND_DEADLINE_BUFFER
        );

        Commitment storage c = commitments[id];
        c.staker = msg.sender;
        c.verifier = p.verifier;
        c.beneficiary = p.beneficiary;
        c.arbiter = p.arbiter;
        c.amount = received;
        c.verifierSlice = p.verifierSlice;
        c.bondObligationId = obligationId;
        c.challengeBond = p.challengeBond;
        c.arbiterFee = p.arbiterFee;
        c.feeStreamId = feeStreamId;
        c.deadline = p.deadline;
        c.challengeWindow = p.challengeWindow;
        c.arbiterDeadline = p.arbiterDeadline;
        c.status = Status.Active;
        // challengeBondPaid, resolvedAt, challengedAt, resolvedPass, outcome stay zero/false.

        emit Created(id, msg.sender, p.verifier, received, p.verifierSlice, obligationId, p.goal);
    }

    /// @notice Verifier records the verdict on or before the deadline. This only OPENS the
    ///         challenge window — no stake, fee, or bond moves here. The verdict becomes final
    ///         (and money moves) at `finalize` after the window closes unchallenged, or at the
    ///         arbiter's ruling if challenged.
    function resolve(uint256 id, bool passed) external nonReentrant {
        Commitment storage c = commitments[id];
        require(c.status == Status.Active, "NOT_ACTIVE");
        require(msg.sender == c.verifier, "NOT_VERIFIER");
        require(block.timestamp <= c.deadline, "DEADLINE_PASSED");

        c.status = Status.Resolved;
        c.resolvedPass = passed;
        c.resolvedAt = uint64(block.timestamp);

        emit Resolved(id, passed, c.resolvedAt + c.challengeWindow);
    }

    /// @notice The party harmed by the recorded verdict — and only it — may dispute it within
    ///         the challenge window by posting the challenge bond:
    ///         - `fail` verdict -> only the STAKER may challenge (it claims the goal WAS met);
    ///         - `pass` verdict -> only the BENEFICIARY may challenge (it claims it was NOT).
    ///         Caller must `approve` this contract for the bond on USDC first. The challenge
    ///         routes the commitment to the arbiter named at create.
    function challenge(uint256 id) external nonReentrant {
        Commitment storage c = commitments[id];
        require(c.status == Status.Resolved, "NOT_RESOLVED");
        // Inclusive bound: a challenge in the window's last second beats a same-block finalize
        // (which requires strictly-after). The two can never both run.
        require(block.timestamp <= uint256(c.resolvedAt) + c.challengeWindow, "WINDOW_CLOSED");
        address harmed = c.resolvedPass ? c.beneficiary : c.staker;
        require(msg.sender == harmed, "NOT_HARMED_PARTY");

        uint256 balBefore = usdc.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), c.challengeBond);
        uint256 received = usdc.balanceOf(address(this)) - balBefore;
        require(received > 0, "NO_FUNDS");

        c.challengeBondPaid = received;
        totalEscrowed += received;
        c.status = Status.Challenged;
        c.challengedAt = uint64(block.timestamp);

        emit Challenged(id, msg.sender, received, c.challengedAt + c.arbiterDeadline);
    }

    /// @notice The named arbiter rules on a challenged verdict, on or before its deadline.
    ///         Terminal — payouts run here. The arbiter is paid its fixed fee out of the
    ///         challenge bond on BOTH rulings: the fact of ruling pays, not the direction. The
    ///         arbiter rules pass/fail only — it NEVER sets a damage number (§7a).
    ///
    ///         - `overturn == false` (uphold): the verdict stands and pays out as resolved; the
    ///           verifier's slice is released; the challenger's bond is slashed — fee to the
    ///           arbiter, remainder (fee-scale at the §7a band — pennies) to the (honest)
    ///           verifier. Anti-grief.
    ///         - `overturn == true`: the corrected verdict redirects the stake; the verifier's
    ///           slice is slashed and routed by the §7a formula — the harmed party (staker on a
    ///           false fail, beneficiary on a false pass) receives
    ///           `damage = feeAccruedToLyingVerifier + challengerArbiterFeeCost`, both
    ///           on-chain-known quantities (the fee is read from StreamPay state at the slash,
    ///           never from a caller value), and the surplus `slice − damage` is BURNED. The
    ///           fee stream is cancelled atomically (this contract holds the sender-right);
    ///           the unstreamed remainder returns to the staker. The challenger's bond is
    ///           refunded minus the arbiter fee.
    function arbitrate(uint256 id, bool overturn) external nonReentrant {
        Commitment storage c = commitments[id];
        require(c.status == Status.Challenged, "NOT_CHALLENGED");
        require(msg.sender == c.arbiter, "NOT_ARBITER");
        // Inclusive bound, mirroring challenge: a ruling at the deadline's last second beats a
        // same-block silence-finalize (strictly-after).
        require(block.timestamp <= uint256(c.challengedAt) + c.arbiterDeadline, "ARBITER_LATE");

        address challenger = c.resolvedPass ? c.beneficiary : c.staker;
        c.status = Status.Finalized;
        emit Ruled(id, msg.sender, overturn);

        if (!overturn) {
            c.outcome = c.resolvedPass ? Outcome.UpheldPass : Outcome.UpheldFail;
            _routeStake(id, c, c.resolvedPass);
            _releaseSliceIfActive(c.bondObligationId);
            // The verdict survived: the fee is earned; only forward an early-cancel residue.
            _settleFeeStream(id, c, false);
            // Frivolous challenge: bond slashed. Fee to the arbiter, remainder to the verifier.
            uint256 fee = _min(c.arbiterFee, c.challengeBondPaid);
            _routeChallengeBond(id, c.arbiter, fee);
            _routeChallengeBond(id, c.verifier, c.challengeBondPaid - fee);
        } else {
            bool finalPass = !c.resolvedPass;
            c.outcome = finalPass ? Outcome.OverturnedToPass : Outcome.OverturnedToFail;
            _routeStake(id, c, finalPass);
            // §7a table: the harmed party follows the CORRECTED verdict — false fail harms the
            // staker, false pass harms the beneficiary (here identical to the challenger, since
            // only the harmed party may challenge — but routed by the table, not the caller).
            address harmed = finalPass ? c.staker : c.beneficiary;
            uint256 fee = _min(c.arbiterFee, c.challengeBondPaid);
            // Atomic fee-stream cancel + on-chain read of what the lying verifier accrued.
            uint256 feeAccrued = _settleFeeStream(id, c, true);
            // The slash transits through this contract (lock's creditor) and is routed §7a:
            // damage to the harmed party, surplus burned.
            uint256 slice = _slashSliceIfActive(c.bondObligationId);
            if (slice > 0) {
                uint256 damage = feeAccrued + fee;
                uint256 toHarmed = _min(damage, slice);
                if (toHarmed > 0) {
                    _safeTransfer(harmed, toHarmed);
                    emit SliceRouted(id, harmed, toHarmed);
                }
                uint256 surplus = slice - toHarmed;
                if (surplus > 0) {
                    _safeTransfer(BURN_ADDR, surplus);
                    emit SliceRouted(id, BURN_ADDR, surplus);
                }
            }
            _routeChallengeBond(id, c.arbiter, fee);
            _routeChallengeBond(id, challenger, c.challengeBondPaid - fee);
        }

        emit Finalized(id, c.outcome);
    }

    /// @notice Terminal step for the two timeout paths; callable by anyone, strictly after the
    ///         respective window:
    ///         - Resolved + challenge window closed unchallenged -> the verdict pays out and
    ///           the verifier's slice is released (clean path);
    ///         - Challenged + arbiter deadline passed with no ruling -> the challenge FAILS
    ///           CLOSED: the original verdict stands and pays out, the slice is released, the
    ///           challenge bond is returned in full (a silent arbiter proves nothing frivolous)
    ///           and the arbiter is NOT paid. No ruling, no punishment, nobody profits.
    function finalize(uint256 id) external nonReentrant {
        Commitment storage c = commitments[id];

        if (c.status == Status.Resolved) {
            require(block.timestamp > uint256(c.resolvedAt) + c.challengeWindow, "WINDOW_OPEN");
            c.status = Status.Finalized;
            c.outcome = c.resolvedPass ? Outcome.CleanPass : Outcome.CleanFail;
            _routeStake(id, c, c.resolvedPass);
            _releaseSliceIfActive(c.bondObligationId);
            _settleFeeStream(id, c, false);
        } else if (c.status == Status.Challenged) {
            require(
                block.timestamp > uint256(c.challengedAt) + c.arbiterDeadline, "ARBITER_TIME_LEFT"
            );
            address challenger = c.resolvedPass ? c.beneficiary : c.staker;
            c.status = Status.Finalized;
            c.outcome = c.resolvedPass ? Outcome.SilencePass : Outcome.SilenceFail;
            _routeStake(id, c, c.resolvedPass);
            _releaseSliceIfActive(c.bondObligationId);
            _settleFeeStream(id, c, false);
            _routeChallengeBond(id, challenger, c.challengeBondPaid);
        } else {
            revert("NOT_FINALIZABLE");
        }

        emit Finalized(id, c.outcome);
    }

    /// @notice The liveness branch (the v1 bug fix, inverted): if the verifier never resolved
    ///         by the deadline, anyone may trigger the slash. The at-fault party pays — the
    ///         VERIFIER's bonded slice is slashed and routed by §7a: the staker receives
    ///         `damage` (the fee that actually accrued to the no-show verifier, read from
    ///         StreamPay state; the arbiter cost is ZERO on this branch — no challenge, no
    ///         ruling), the surplus is BURNED, and the STAKE IS RETURNED to the staker, not
    ///         handed to the beneficiary. The fee stream is cancelled ATOMICALLY in this same
    ///         transaction (spec §7: a verifier that does no work earns nothing more); the
    ///         unstreamed remainder returns to the staker. Fully on-chain provable; no oracle,
    ///         no arbiter. Terminal.
    function slashVerifierExpired(uint256 id) external nonReentrant {
        Commitment storage c = commitments[id];
        require(c.status == Status.Active, "NOT_ACTIVE");
        require(block.timestamp > c.deadline, "NOT_EXPIRED");

        c.status = Status.Expired;
        c.outcome = Outcome.LivenessSlash;

        // Atomic cancel first (§7 liveness branch): the contract does not rely on the staker
        // to remember. Also yields the on-chain `feeAccrued` damage input.
        uint256 feeAccrued = _settleFeeStream(id, c, true);
        uint256 slice = _slashSliceIfActive(c.bondObligationId);
        if (slice > 0) {
            // §7a: damage = feeAccrued + 0 (no arbiter on this branch); surplus burned.
            uint256 toStaker = _min(feeAccrued, slice);
            if (toStaker > 0) {
                _safeTransfer(c.staker, toStaker);
                emit SliceRouted(id, c.staker, toStaker);
            }
            uint256 surplus = slice - toStaker;
            if (surplus > 0) {
                _safeTransfer(BURN_ADDR, surplus);
                emit SliceRouted(id, BURN_ADDR, surplus);
            }
        }
        totalEscrowed -= c.amount;
        _safeTransfer(c.staker, c.amount);
        emit StakeRouted(id, c.staker, c.amount);

        emit Finalized(id, c.outcome);
    }

    // --- views ---

    /// @notice Convenience view returning the full commitment record.
    function get(uint256 id) external view returns (Commitment memory) {
        return commitments[id];
    }

    /// @notice The minimum challenge bond `create` accepts (§7a post-burn floor):
    ///         arbiterFee + 10% of the SLICE (rounded up). Sized against the post-burn
    ///         capturable prize (`damage`, ≈ pennies), not the stake and not the slice.
    function challengeBondFloor(uint256 verifierSlice, uint256 arbiterFee)
        public
        pure
        returns (uint256)
    {
        // Round the margin up so the floored bond always carries a non-zero spam margin.
        return arbiterFee + (verifierSlice * SPAM_MARGIN_MIN_BPS + BPS_DENOM - 1) / BPS_DENOM;
    }

    /// @notice The maximum challenge bond `create` accepts (§7a band upper constraint):
    ///         arbiterFee + 25% of the SLICE — a legitimate harmed party risks at most a
    ///         fee-scale bond to recover a stake-scale loss, never priced out of challenging.
    function challengeBondCap(uint256 verifierSlice, uint256 arbiterFee)
        public
        pure
        returns (uint256)
    {
        return arbiterFee + (verifierSlice * SPAM_MARGIN_MAX_BPS) / BPS_DENOM;
    }

    /// @notice Recommended verifier slice for a given stake and fee budget: 150% of the stake,
    ///         raised when the fee budget reaches 50% of the stake (the large-fee guard). Always
    ///         satisfies the enforced strict inequality `slice > amount + maxAccruableFee`.
    function recommendedSlice(uint256 amount, uint256 maxAccruableFee)
        public
        pure
        returns (uint256)
    {
        uint256 byDefault = (amount * DEFAULT_SLICE_BPS) / BPS_DENOM;
        uint256 byGuard = amount + maxAccruableFee + 1;
        return byDefault > byGuard ? byDefault : byGuard;
    }

    // --- internal routing helpers ---

    /// @dev Push the stake per the (final) verdict: pass -> staker, fail -> beneficiary.
    function _routeStake(uint256 id, Commitment storage c, bool finalPass) private {
        address to = finalPass ? c.staker : c.beneficiary;
        totalEscrowed -= c.amount;
        _safeTransfer(to, c.amount);
        emit StakeRouted(id, to, c.amount);
    }

    /// @dev Route a leg of the posted challenge bond, skipping empty legs.
    function _routeChallengeBond(uint256 id, address to, uint256 amount) private {
        if (amount == 0) return;
        totalEscrowed -= amount;
        _safeTransfer(to, amount);
        emit ChallengeBondRouted(id, to, amount);
    }

    /// @dev Settle the registered fee stream at a terminal step and report the fee that
    ///      ACTUALLY accrued to the verifier — read from StreamPay's own state, never from a
    ///      caller-supplied value (a parameter would let the lying party or the challenger
    ///      inject a fake damage; the two are NOT security-equivalent).
    ///
    ///      - `slashPath == true` (overturn / liveness): cancel the stream atomically — this
    ///        contract is the stream SENDER, which is the entire reason it opens the stream
    ///        itself at create. The unstreamed remainder is refunded by StreamPay to this
    ///        contract and forwarded to the staker in the same transaction. After `cancel`,
    ///        StreamPay freezes `withdrawn` to the final streamed total — that is the
    ///        `feeAccruedToLyingVerifier` damage input.
    ///      - `slashPath == false` (clean / upheld / silence): the fee is earned and the stream
    ///        keeps running. Only an early-Ended stream (the verifier cancelled or fully
    ///        withdrew before the terminal step) needs handling: a recipient-side cancel
    ///        refunded the remainder to this contract back then; forward it to the staker now.
    ///        Returns 0 — accrued fee is irrelevant on a non-slash path.
    function _settleFeeStream(uint256 id, Commitment storage c, bool slashPath)
        private
        returns (uint256 feeAccrued)
    {
        uint256 sid = c.feeStreamId;
        if (sid == 0) return 0;

        IStreamPay.Stream memory s = streamPay.get(sid);
        uint256 refunded;
        if (s.status == IStreamPay.StreamStatus.Active) {
            if (!slashPath) return 0; // earned fee streams on undisturbed
            uint256 balBefore = usdc.balanceOf(address(this));
            streamPay.cancel(sid);
            refunded = usdc.balanceOf(address(this)) - balBefore;
            // cancel froze `withdrawn` at the total streamed: the on-chain accrued amount.
            feeAccrued = streamPay.get(sid).withdrawn;
        } else {
            // Ended before the terminal step (recipient-side cancel or full withdraw). Any
            // unstreamed remainder already sits in this contract from that cancel; the staker
            // funded the fee, so it goes back to the staker. Cap at the UNBOOKED balance
            // (holdings above `totalEscrowed`): with the standard production token the cap is
            // never binding (the refund arrived 1:1), but a fee-on-transfer skim on the inbound
            // refund must never be paid out of another commitment's escrow.
            feeAccrued = s.withdrawn;
            uint256 unbooked = usdc.balanceOf(address(this)) - totalEscrowed;
            refunded = _min(s.deposit - s.withdrawn, unbooked);
        }
        if (refunded > 0) _safeTransfer(c.staker, refunded);
        emit FeeStreamSettled(id, feeAccrued, refunded);
    }

    /// @dev Release the verifier's slice if the obligation is still open. If the AgentBond
    ///      backstop deadline passed and the verifier already self-released (this contract was
    ///      effectively abandoned for the buffer period), the slice is simply gone from our
    ///      control — stake routing still completes. Normal flow never hits this.
    function _releaseSliceIfActive(uint256 obligationId) private {
        if (agentBond.getObligation(obligationId).status == IAgentBond.ObligationStatus.Active) {
            agentBond.release(obligationId);
        }
    }

    /// @dev Slash the verifier's slice to this contract (the lock's creditor) and report the
    ///      amount that actually arrived (balance delta), to be routed by the §7a rule. Same
    ///      backstop semantics as release: if the verifier self-released after the AgentBond
    ///      deadline, there is nothing left to slash and 0 is returned.
    function _slashSliceIfActive(uint256 obligationId) private returns (uint256 received) {
        if (agentBond.getObligation(obligationId).status != IAgentBond.ObligationStatus.Active) {
            return 0;
        }
        uint256 balBefore = usdc.balanceOf(address(this));
        agentBond.slash(obligationId);
        received = usdc.balanceOf(address(this)) - balBefore;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    // --- safe ERC-20 helpers (tolerate non-standard no-return tokens) ---

    function _safeTransfer(address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(usdc).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function _safeTransferFrom(address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(usdc).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }

    function _safeApprove(address spender, uint256 amount) private {
        (bool ok, bytes memory data) =
            address(usdc).call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "APPROVE_FAILED");
    }
}
