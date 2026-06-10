// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 surface used by CommitStake (Arc USDC is ERC-20 + the gas token).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
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

/// @title CommitStake
/// @notice A generic "skin in the game" primitive for Arc. A staker locks USDC behind a
///         commitment. A trusted verifier confirms success before the deadline:
///           - success  -> the staker reclaims the full stake,
///           - failure  -> the stake is slashed to a beneficiary,
///           - no answer by the deadline -> anyone can trigger the slash (verifier can't grief
///             by going silent).
///
///         The contract holds no admin keys, has no owner, and never custodies funds beyond
///         the individual escrows. It is a public protocol: anyone can create a commitment,
///         pick any verifier and beneficiary, and build products on top (language tests,
///         fitness goals, code challenges, habit tracking).
///
///         USDC has 6 decimals; all amounts are in micro-USDC.
contract CommitStake is ReentrancyGuard {
    enum Status {
        None, // 0 - never created
        Active, // 1 - funded, awaiting resolution
        Passed, // 2 - verifier confirmed success, staker may claim
        Claimed, // 3 - staker reclaimed the stake
        Slashed // 4 - stake sent to the beneficiary
    }

    struct Commitment {
        address staker; // who locked the funds and gets them back on success
        address verifier; // the only party that can mark success/failure before the deadline
        address beneficiary; // receives the stake if the commitment fails or expires
        uint256 amount; // micro-USDC locked
        uint64 deadline; // unix seconds; resolution must happen on or before this
        Status status;
    }

    IERC20 public immutable usdc;

    uint256 public nextId = 1;
    mapping(uint256 => Commitment) public commitments;

    event Created(
        uint256 indexed id,
        address indexed staker,
        address indexed verifier,
        address beneficiary,
        uint256 amount,
        uint64 deadline,
        string goal
    );
    event Resolved(uint256 indexed id, bool passed);
    event Claimed(uint256 indexed id, address indexed staker, uint256 amount);
    event Slashed(uint256 indexed id, address indexed beneficiary, uint256 amount, bool expired);

    constructor(IERC20 _usdc) {
        require(address(_usdc) != address(0), "USDC_ZERO");
        usdc = _usdc;
    }

    /// @notice Lock `amount` USDC behind a new commitment. Caller must `approve` this contract
    ///         for `amount` on the USDC token first.
    /// @param verifier    address allowed to mark pass/fail before the deadline.
    /// @param beneficiary address that receives the stake on failure/expiry.
    /// @param amount      micro-USDC to lock (must be > 0).
    /// @param deadline    unix seconds; must be in the future.
    /// @param goal        human-readable description (emitted only, not stored on-chain).
    /// @return id         the new commitment id.
    function create(
        address verifier,
        address beneficiary,
        uint256 amount,
        uint64 deadline,
        string calldata goal
    ) external nonReentrant returns (uint256 id) {
        require(amount > 0, "AMOUNT_ZERO");
        require(verifier != address(0), "VERIFIER_ZERO");
        require(beneficiary != address(0), "BENEFICIARY_ZERO");
        require(deadline > block.timestamp, "DEADLINE_PAST");

        id = nextId++;

        // Balance-delta accounting: book what actually arrived (balanceOf delta), not what was
        // asked for, so a later claim/slash never pays out more than the escrow received.
        // Unit-tested with fee-on-transfer and no-return tokens; the production token is Arc
        // USDC (standard 1:1 ERC-20). Other exotic ERC-20 behaviours are out of scope.
        uint256 balBefore = usdc.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdc.balanceOf(address(this)) - balBefore;
        require(received > 0, "NO_FUNDS");

        commitments[id] = Commitment({
            staker: msg.sender,
            verifier: verifier,
            beneficiary: beneficiary,
            amount: received,
            deadline: deadline,
            status: Status.Active
        });

        emit Created(id, msg.sender, verifier, beneficiary, received, deadline, goal);
    }

    /// @notice Verifier records the outcome. Must be called on or before the deadline.
    ///         `passed == true` unlocks the stake for the staker to claim.
    ///         `passed == false` slashes the stake to the beneficiary immediately.
    function resolve(uint256 id, bool passed) external nonReentrant {
        Commitment storage c = commitments[id];
        require(c.status == Status.Active, "NOT_ACTIVE");
        require(msg.sender == c.verifier, "NOT_VERIFIER");
        require(block.timestamp <= c.deadline, "DEADLINE_PASSED");

        if (passed) {
            c.status = Status.Passed;
            emit Resolved(id, true);
        } else {
            c.status = Status.Slashed;
            emit Resolved(id, false);
            _safeTransfer(c.beneficiary, c.amount);
            emit Slashed(id, c.beneficiary, c.amount, false);
        }
    }

    /// @notice Staker reclaims the stake after a successful resolution.
    function claim(uint256 id) external nonReentrant {
        Commitment storage c = commitments[id];
        require(c.status == Status.Passed, "NOT_PASSED");
        require(msg.sender == c.staker, "NOT_STAKER");

        c.status = Status.Claimed;
        _safeTransfer(c.staker, c.amount);
        emit Claimed(id, c.staker, c.amount);
    }

    /// @notice After the deadline with no successful resolution, anyone can push the stake to
    ///         the beneficiary. This removes the verifier's ability to grief by staying silent.
    function slashExpired(uint256 id) external nonReentrant {
        Commitment storage c = commitments[id];
        require(c.status == Status.Active, "NOT_ACTIVE");
        require(block.timestamp > c.deadline, "NOT_EXPIRED");

        c.status = Status.Slashed;
        _safeTransfer(c.beneficiary, c.amount);
        emit Slashed(id, c.beneficiary, c.amount, true);
    }

    /// @notice Convenience view returning the full commitment record.
    function get(uint256 id) external view returns (Commitment memory) {
        return commitments[id];
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
}
