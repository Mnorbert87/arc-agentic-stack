// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 surface. Arc USDC is both the gas token and an ERC-20 (6 decimals).
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

/// @title AgentBond
/// @notice The shared enforcement primitive behind reputation-backed agent products on Arc.
///         An agent posts a USDC bond — skin-in-the-game backing its on-chain reputation — and
///         then *grants slashing allowance* to specific protocol contracts (a credit line, a
///         marketplace escrow, an insurer). This mirrors ERC-20 `approve`: the agent opts in to
///         each protocol it trusts; nothing can touch the bond without an explicit grant.
///
///         An approved enforcer can `lock` a slice of the bond behind an obligation, then either
///         `release` it (obligation settled — capacity returns, revolving) or `slash` it to a
///         creditor (the agent defaulted — the bond pays, capacity is burned). The free (unlocked)
///         bond is the number other parties read to decide how much to trust the agent.
///
///         No owner, no admin, no upgrade key. The contract custodies only the bonds, tracked by
///         actual balance delta so it stays solvent against any non-standard ERC-20.
///
///         USDC has 6 decimals; all amounts are micro-USDC.
contract AgentBond is ReentrancyGuard {
    enum Status {
        None, // 0 - never created
        Active, // 1 - bond locked behind an open obligation
        Released, // 2 - obligation settled, bond returned to free balance
        Slashed // 3 - agent defaulted, bond paid to the creditor
    }

    struct Obligation {
        address agent; // whose bond is on the hook
        address enforcer; // the protocol contract that opened it (only it can resolve)
        address creditor; // where a slash sends the funds
        uint256 amount; // micro-USDC locked
        uint64 deadline; // 0 = no expiry; if set, the agent may self-release after this time
        Status status;
    }

    IERC20 public immutable usdc;

    /// @notice Total bond an agent has deposited (free + locked).
    mapping(address => uint256) public bond;
    /// @notice Portion of an agent's bond currently locked behind open obligations.
    mapping(address => uint256) public locked;
    /// @notice Slashing allowance an agent grants to an enforcer contract (revolving capacity).
    mapping(address => mapping(address => uint256)) public slashAllowance;

    uint256 public nextObligationId = 1;
    mapping(uint256 => Obligation) public obligations;

    event Deposited(address indexed agent, uint256 amount, uint256 newBond);
    event Withdrawn(address indexed agent, uint256 amount, uint256 newBond);
    event AllowanceSet(address indexed agent, address indexed enforcer, uint256 amount);
    event Locked(
        uint256 indexed id,
        address indexed agent,
        address indexed enforcer,
        address creditor,
        uint256 amount,
        uint64 deadline
    );
    event Released(uint256 indexed id, address indexed agent, uint256 amount);
    event Slashed(uint256 indexed id, address indexed agent, address indexed creditor, uint256 amount);

    constructor(IERC20 _usdc) {
        require(address(_usdc) != address(0), "USDC_ZERO");
        usdc = _usdc;
    }

    // --- agent: fund and manage the bond ---

    /// @notice Top up the caller's bond. Caller must `approve` this contract on USDC first.
    ///         Records the balance actually received (fee-on-transfer / rebasing safe).
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT_ZERO");
        uint256 balBefore = usdc.balanceOf(address(this));
        _safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdc.balanceOf(address(this)) - balBefore;
        require(received > 0, "NO_FUNDS");

        bond[msg.sender] += received;
        emit Deposited(msg.sender, received, bond[msg.sender]);
    }

    /// @notice Withdraw free (unlocked) bond. Locked bond cannot be pulled until the enforcer
    ///         that locked it releases the obligation.
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT_ZERO");
        uint256 free = bond[msg.sender] - locked[msg.sender];
        require(amount <= free, "INSUFFICIENT_FREE");

        bond[msg.sender] -= amount;
        _safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, bond[msg.sender]);
    }

    /// @notice Grant (or revoke, with 0) an enforcer contract the right to lock and slash up to
    ///         `amount` of the caller's bond. Set to the exact revolving capacity you want that
    ///         protocol to have. Only ever trust audited enforcer code with this.
    function setSlashAllowance(address enforcer, uint256 amount) external {
        require(enforcer != address(0), "ENFORCER_ZERO");
        slashAllowance[msg.sender][enforcer] = amount;
        emit AllowanceSet(msg.sender, enforcer, amount);
    }

    // --- enforcer: open and resolve obligations ---

    /// @notice Called by an approved enforcer to lock `amount` of `agent`'s free bond behind a new
    ///         obligation. Spends the enforcer's slashing allowance for that agent.
    /// @param deadline unix seconds after which the agent may self-`release` an unresolved
    ///        obligation. Pass `0` for no expiry (the enforcer must then resolve it). A non-zero
    ///        deadline closes the indefinite-lock griefing vector: the agent can always reclaim a
    ///        bond an enforcer abandons, without anyone being slashed.
    /// @return id the new obligation id.
    function lock(address agent, address creditor, uint256 amount, uint64 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        require(amount > 0, "AMOUNT_ZERO");
        require(creditor != address(0), "CREDITOR_ZERO");

        uint256 allowed = slashAllowance[agent][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        uint256 free = bond[agent] - locked[agent];
        require(free >= amount, "INSUFFICIENT_BOND");

        slashAllowance[agent][msg.sender] = allowed - amount;
        locked[agent] += amount;

        id = nextObligationId++;
        obligations[id] = Obligation({
            agent: agent,
            enforcer: msg.sender,
            creditor: creditor,
            amount: amount,
            deadline: deadline,
            status: Status.Active
        });

        emit Locked(id, agent, msg.sender, creditor, amount, deadline);
    }

    /// @notice Obligation settled: unlock the bond and return the revolving capacity to the
    ///         enforcer's allowance. The enforcer may call this at any time. The agent may call it
    ///         only after a non-zero `deadline` has passed, to reclaim a bond an enforcer abandoned.
    function release(uint256 id) external nonReentrant {
        Obligation storage o = obligations[id];
        require(o.status == Status.Active, "NOT_ACTIVE");
        bool byEnforcer = msg.sender == o.enforcer;
        bool byAgentExpired =
            msg.sender == o.agent && o.deadline != 0 && block.timestamp > o.deadline;
        require(byEnforcer || byAgentExpired, "NOT_AUTHORIZED");

        o.status = Status.Released;
        locked[o.agent] -= o.amount;
        slashAllowance[o.agent][o.enforcer] += o.amount;

        emit Released(id, o.agent, o.amount);
    }

    /// @notice Agent defaulted: pay the locked bond to the creditor. Capacity is NOT restored —
    ///         a slash permanently burns that slice of the grant. Only the opening enforcer may call.
    function slash(uint256 id) external nonReentrant {
        Obligation storage o = obligations[id];
        require(o.status == Status.Active, "NOT_ACTIVE");
        require(msg.sender == o.enforcer, "NOT_ENFORCER");

        o.status = Status.Slashed;
        locked[o.agent] -= o.amount;
        bond[o.agent] -= o.amount;

        _safeTransfer(o.creditor, o.amount);
        emit Slashed(id, o.agent, o.creditor, o.amount);
    }

    // --- views ---

    /// @notice Free (unlocked) bond — the number a counterparty reads to size its trust.
    function freeBondOf(address agent) external view returns (uint256) {
        return bond[agent] - locked[agent];
    }

    /// @notice Full obligation record.
    function getObligation(uint256 id) external view returns (Obligation memory) {
        return obligations[id];
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
