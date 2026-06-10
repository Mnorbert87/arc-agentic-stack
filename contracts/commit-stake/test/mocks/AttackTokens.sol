// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommitStake} from "../../src/CommitStake.sol";

/// @dev A token whose transfer() reenters CommitStake. Proves the mutex + CEI hold:
///      the reentrant call must fail and there must be NO double payout.
contract ReentrantToken {
    string public name = "Evil USDC";
    string public symbol = "eUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    CommitStake public target;
    uint256 public reentryId;
    bool public reentryAttempted;
    bool public reentryReverted;

    function setTarget(CommitStake _t, uint256 _id) external {
        target = _t;
        reentryId = _id;
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
        // On the way OUT of the escrow, try to reenter and double-claim/double-slash.
        if (address(target) != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            try target.claim(reentryId) {
                // reentry succeeded -> contract is broken
            } catch {
                reentryReverted = true;
            }
            try target.slashExpired(reentryId) {} catch {}
        }
        _transfer(msg.sender, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

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
        uint256 net = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += net; // fee is burned (skimmed)
    }
}

/// @dev Returns no data (like USDT) — never reverts on success. Proves the safe-transfer
///      helper tolerates non-bool ERC-20s.
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
