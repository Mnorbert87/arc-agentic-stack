// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentBond, IERC20} from "../src/AgentBond.sol";

/// @dev Fee-on-transfer token: skims `feeBps` on every transfer/transferFrom.
contract FeeToken {
    string public name = "Fee USDC";
    string public symbol = "fUSDC";
    uint8 public decimals = 6;
    uint256 public immutable feeBps; // e.g. 1000 = 10%

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _feeBps) {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOWANCE");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BALANCE");
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee; // fee is burned (skimmed)
    }
}

/// @dev Returns no data (like USDT) — never reverts on success. Proves the safe-transfer
///      helpers tolerate non-bool ERC-20s.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ALLOWANCE");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "BALANCE");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Unit evidence behind the custody claim in AgentBond's NatSpec: balance-delta
///         accounting books only what actually arrived, so the contract stays solvent BY ITS
///         OWN BOOKS under a fee-on-transfer token, and the safe-transfer helpers tolerate
///         no-return (USDT-style) tokens. Mirrors the CommitStake/StreamPay adversarial pattern.
contract AgentBondFeeTokenTest is Test {
    uint256 constant UNIT = 1e6;

    address agentA = address(0xA1);
    address agentB = address(0xA2);
    address enforcer = address(0xE1);
    address creditor = address(0xC1);

    // ----------------------------------------------------------------------------------
    // 1. Fee-on-transfer deposits: each bond books only the net amount received, so two
    //    agents can BOTH fully withdraw. With naive custody the second withdraw reverts.
    // ----------------------------------------------------------------------------------
    function test_feeOnTransfer_depositBooksReceived_bothCanExit() public {
        FeeToken fee = new FeeToken(1000); // 10% skim
        AgentBond bond = new AgentBond(IERC20(address(fee)));

        fee.mint(agentA, 100 * UNIT);
        fee.mint(agentB, 100 * UNIT);
        vm.prank(agentA);
        fee.approve(address(bond), type(uint256).max);
        vm.prank(agentB);
        fee.approve(address(bond), type(uint256).max);

        vm.prank(agentA);
        bond.deposit(100 * UNIT);
        vm.prank(agentB);
        bond.deposit(100 * UNIT);

        // each bond booked only the 90 that actually arrived
        assertEq(bond.bond(agentA), 90 * UNIT, "A bond not net-of-fee");
        assertEq(bond.bond(agentB), 90 * UNIT, "B bond not net-of-fee");
        assertEq(fee.balanceOf(address(bond)), 180 * UNIT, "escrow holds both net bonds");

        // both can withdraw their FULL booked bond — no insolvency
        vm.prank(agentA);
        bond.withdraw(90 * UNIT);
        vm.prank(agentB);
        bond.withdraw(90 * UNIT); // would revert BALANCE if custody were naive

        assertEq(fee.balanceOf(address(bond)), 0, "funds stuck after both exits");
    }

    // ----------------------------------------------------------------------------------
    // 2. Fee-on-transfer full lifecycle (deposit -> allowance -> lock -> slash -> withdraw):
    //    by its own books the contract stays exactly solvent — escrow balance always equals
    //    the sum of booked bonds; the outbound skim hits the recipient, never the escrow.
    // ----------------------------------------------------------------------------------
    function test_feeOnTransfer_slashLifecycle_staysSolventByOwnBooks() public {
        FeeToken fee = new FeeToken(1000);
        AgentBond bond = new AgentBond(IERC20(address(fee)));

        fee.mint(agentA, 100 * UNIT);
        vm.startPrank(agentA);
        fee.approve(address(bond), type(uint256).max);
        bond.deposit(100 * UNIT); // books 90
        bond.setSlashAllowance(enforcer, 90 * UNIT);
        vm.stopPrank();

        vm.prank(enforcer);
        uint256 id = bond.lock(agentA, creditor, 30 * UNIT, 0);
        vm.prank(enforcer);
        bond.slash(id);

        // escrow released exactly the booked 30; the creditor's 10% haircut is the token's
        // doing on the way out, not an escrow shortfall
        assertEq(fee.balanceOf(creditor), 27 * UNIT, "creditor net-of-fee payout");
        assertEq(bond.bond(agentA), 60 * UNIT);
        assertEq(bond.locked(agentA), 0);
        assertEq(fee.balanceOf(address(bond)), 60 * UNIT, "escrow != sum of booked bonds");

        // the remaining booked bond is withdrawable in full
        vm.prank(agentA);
        bond.withdraw(60 * UNIT);
        assertEq(fee.balanceOf(address(bond)), 0, "funds stuck after final exit");
    }

    // ----------------------------------------------------------------------------------
    // 3. No-return (USDT-style) token: the safe-transfer helpers must tolerate empty
    //    returndata across the whole lifecycle.
    // ----------------------------------------------------------------------------------
    function test_noReturnToken_fullLifecycle() public {
        NoReturnToken t = new NoReturnToken();
        AgentBond bond = new AgentBond(IERC20(address(t)));

        t.mint(agentA, 100 * UNIT);
        vm.startPrank(agentA);
        t.approve(address(bond), 100 * UNIT);
        bond.deposit(100 * UNIT);
        bond.setSlashAllowance(enforcer, 100 * UNIT);
        vm.stopPrank();

        vm.startPrank(enforcer);
        uint256 idReleased = bond.lock(agentA, creditor, 40 * UNIT, 0);
        uint256 idSlashed = bond.lock(agentA, creditor, 30 * UNIT, 0);
        bond.release(idReleased);
        bond.slash(idSlashed);
        vm.stopPrank();

        assertEq(t.balanceOf(creditor), 30 * UNIT);
        assertEq(bond.bond(agentA), 70 * UNIT);
        assertEq(bond.locked(agentA), 0);

        vm.prank(agentA);
        bond.withdraw(70 * UNIT);
        assertEq(t.balanceOf(agentA), 70 * UNIT);
        assertEq(t.balanceOf(address(bond)), 0, "funds stuck with no-return token");
    }
}
