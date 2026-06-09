// Arc Agentic Stack SDK — one small wrapper over AgentBond + StreamPay on Arc.
//
// ethers v6 is a peer dependency. In Node: `npm i ethers`. In the browser, map the
// bare "ethers" specifier with an import map or import this file from a bundler.
//
//   import { ethers } from "ethers";
//   import { ArcAgenticStack } from "@arc/agentic-stack-sdk";
//
//   const signer = new ethers.Wallet(PRIVATE_KEY, ArcAgenticStack.provider());
//   const arc = new ArcAgenticStack(signer);
//
// Every amount argument is a human USDC string/number ("10" = 10 USDC); the SDK
// converts to micro-USDC (6 decimals) for you. Views return both `.raw` (bigint
// micro-USDC) and `.usdc` (formatted string) so you never juggle decimals.
import { ethers } from "ethers";

/** Arc testnet network + deployed addresses, baked in. */
export const ARC = Object.freeze({
  chainId: 5042002,
  rpcUrl: "https://rpc.testnet.arc.network",
  wsUrl: "wss://rpc.testnet.arc.network",
  explorer: "https://testnet.arcscan.app",
  usdcDecimals: 6,
  contracts: Object.freeze({
    AgentBond: "0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0",
    StreamPay: "0x505739d33D85AD85D0f9eeE64856309782382450",
    USDC: "0x3600000000000000000000000000000000000000",
  }),
});

const AGENT_BOND_ABI = [
  "function deposit(uint256 amount)",
  "function withdraw(uint256 amount)",
  "function setSlashAllowance(address enforcer, uint256 amount)",
  "function lock(address agent, address creditor, uint256 amount, uint64 deadline) returns (uint256 id)",
  "function release(uint256 id)",
  "function slash(uint256 id)",
  "function bond(address) view returns (uint256)",
  "function locked(address) view returns (uint256)",
  "function freeBondOf(address) view returns (uint256)",
  "function slashAllowance(address agent, address enforcer) view returns (uint256)",
  "function nextObligationId() view returns (uint256)",
  "function getObligation(uint256 id) view returns (tuple(address agent, address enforcer, address creditor, uint256 amount, uint64 deadline, uint8 status))",
  "function usdc() view returns (address)",
  "event Locked(uint256 indexed id, address indexed agent, address indexed enforcer, address creditor, uint256 amount, uint64 deadline)",
];

const STREAM_PAY_ABI = [
  "function createStream(address recipient, uint256 deposit, uint64 start, uint64 stop, string memo) returns (uint256 id)",
  "function withdraw(uint256 id, uint256 amount)",
  "function cancel(uint256 id)",
  "function streamedTotal(uint256 id) view returns (uint256)",
  "function recipientBalance(uint256 id) view returns (uint256)",
  "function senderBalance(uint256 id) view returns (uint256)",
  "function nextId() view returns (uint256)",
  "function get(uint256 id) view returns (tuple(address sender, address recipient, uint256 deposit, uint256 withdrawn, uint64 start, uint64 stop, uint8 status))",
  "function usdc() view returns (address)",
  "event Created(uint256 indexed id, address indexed sender, address indexed recipient, uint256 deposit, uint64 start, uint64 stop, string memo)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

const OBLIGATION_STATUS = ["None", "Active", "Released", "Slashed"];
const STREAM_STATUS = ["None", "Active", "Ended"];

/** A read-only JsonRpcProvider pinned to Arc testnet. */
function arcProvider() {
  return new ethers.JsonRpcProvider(ARC.rpcUrl, ARC.chainId);
}

/** Wrap a bigint micro-USDC amount with a formatted view. */
function usdcAmount(raw) {
  return { raw, usdc: ethers.formatUnits(raw, ARC.usdcDecimals) };
}

export class ArcAgenticStack {
  /**
   * @param {ethers.Signer|ethers.Provider} runner a Signer (to send tx) or a
   *        Provider (read-only). Views work with either; writes need a Signer.
   * @param {object} [overrides] optional { AgentBond, StreamPay, USDC } address overrides.
   */
  constructor(runner, overrides = {}) {
    if (!runner) throw new Error("ArcAgenticStack: pass an ethers Signer or Provider");
    this.runner = runner;
    this.addresses = { ...ARC.contracts, ...overrides };
    this.agentBond = new ethers.Contract(this.addresses.AgentBond, AGENT_BOND_ABI, runner);
    this.streamPay = new ethers.Contract(this.addresses.StreamPay, STREAM_PAY_ABI, runner);
    this.usdc = new ethers.Contract(this.addresses.USDC, ERC20_ABI, runner);
  }

  /** A read-only Arc provider — handy for `new ethers.Wallet(key, ArcAgenticStack.provider())`. */
  static provider() {
    return arcProvider();
  }

  /** Read-only instance straight off the public RPC (no key needed). */
  static readOnly(overrides = {}) {
    return new ArcAgenticStack(arcProvider(), overrides);
  }

  /** micro-USDC bigint from a human amount ("10" -> 10000000n). */
  toUnits(amount) {
    return ethers.parseUnits(String(amount), ARC.usdcDecimals);
  }

  /** human USDC string from a micro-USDC bigint. */
  fromUnits(units) {
    return ethers.formatUnits(units, ARC.usdcDecimals);
  }

  async _address() {
    if (typeof this.runner.getAddress === "function") return this.runner.getAddress();
    throw new Error("This call needs a Signer (got a read-only Provider)");
  }

  // --- USDC helpers ----------------------------------------------------------

  /** Approve a stack contract to pull `amount` USDC. Pass "max" for unlimited. */
  async approveUsdc(spender, amount) {
    const value = amount === "max" ? ethers.MaxUint256 : this.toUnits(amount);
    const tx = await this.usdc.approve(spender, value);
    return tx.wait();
  }

  async usdcBalanceOf(address) {
    return usdcAmount(await this.usdc.balanceOf(address));
  }

  // --- AgentBond: trust layer ------------------------------------------------

  /**
   * Post (top up) the caller's bond. Approves USDC first unless you pass
   * { approve:false } (e.g. you already granted allowance).
   */
  async bond(amount, { approve = true } = {}) {
    if (approve) await this.approveUsdc(this.addresses.AgentBond, amount);
    const tx = await this.agentBond.deposit(this.toUnits(amount));
    return tx.wait();
  }

  /** Withdraw free (unlocked) bond back to the caller. */
  async unbond(amount) {
    const tx = await this.agentBond.withdraw(this.toUnits(amount));
    return tx.wait();
  }

  /** Grant (or revoke with 0) an enforcer the right to lock/slash up to `amount` of your bond. */
  async setSlashAllowance(enforcer, amount) {
    const tx = await this.agentBond.setSlashAllowance(enforcer, this.toUnits(amount));
    return tx.wait();
  }

  /**
   * Enforcer-side: lock `amount` of `agent`'s bond behind a new obligation.
   * Returns { id, receipt }. `deadline` is unix seconds (0 = no expiry).
   */
  async lock(agent, creditor, amount, deadline = 0) {
    const tx = await this.agentBond.lock(agent, creditor, this.toUnits(amount), BigInt(deadline));
    const receipt = await tx.wait();
    const id = this._eventId(receipt, this.agentBond, "Locked");
    return { id, receipt };
  }

  /** Resolve an obligation as performed — bond unlocks, capacity returns. */
  async release(id) {
    const tx = await this.agentBond.release(id);
    return tx.wait();
  }

  /** Resolve an obligation as defaulted — bond pays the creditor. */
  async slash(id) {
    const tx = await this.agentBond.slash(id);
    return tx.wait();
  }

  /** Free (unlocked) bond — the number a counterparty reads to size its trust. */
  async freeBondOf(agent) {
    return usdcAmount(await this.agentBond.freeBondOf(agent));
  }

  /** Full bond breakdown for an agent. */
  async bondOf(agent) {
    const [total, locked] = await Promise.all([
      this.agentBond.bond(agent),
      this.agentBond.locked(agent),
    ]);
    return { total: usdcAmount(total), locked: usdcAmount(locked), free: usdcAmount(total - locked) };
  }

  async slashAllowanceOf(agent, enforcer) {
    return usdcAmount(await this.agentBond.slashAllowance(agent, enforcer));
  }

  /** Decoded obligation record. */
  async getObligation(id) {
    const o = await this.agentBond.getObligation(id);
    return {
      agent: o.agent,
      enforcer: o.enforcer,
      creditor: o.creditor,
      amount: usdcAmount(o.amount),
      deadline: Number(o.deadline),
      status: OBLIGATION_STATUS[Number(o.status)] ?? "Unknown",
    };
  }

  // --- StreamPay: settlement layer -------------------------------------------

  /**
   * Open a USDC payment stream to `recipient` accruing linearly from `start` to
   * `stop` (unix seconds; omit start to begin now). Approves USDC unless
   * { approve:false }. Returns { id, receipt }.
   */
  async createStream(recipient, amount, { start, stop, durationSeconds, memo = "", approve = true } = {}) {
    const now = Math.floor(Date.now() / 1000);
    const s = start ?? now;
    const e = stop ?? (durationSeconds ? s + durationSeconds : undefined);
    if (!e) throw new Error("createStream: provide stop or durationSeconds");
    if (approve) await this.approveUsdc(this.addresses.StreamPay, amount);
    const tx = await this.streamPay.createStream(recipient, this.toUnits(amount), BigInt(s), BigInt(e), memo);
    const receipt = await tx.wait();
    const id = this._eventId(receipt, this.streamPay, "Created");
    return { id, receipt };
  }

  /** Recipient withdraws streamed-so-far funds. Pass amount or "all". */
  async withdraw(id, amount = "all") {
    const value = amount === "all" ? 0n : this.toUnits(amount);
    const tx = await this.streamPay.withdraw(id, value);
    return tx.wait();
  }

  /** Either party cancels: recipient keeps the streamed part, sender reclaims the rest. */
  async cancel(id) {
    const tx = await this.streamPay.cancel(id);
    return tx.wait();
  }

  /** micro-USDC currently withdrawable by the recipient. */
  async recipientBalance(id) {
    return usdcAmount(await this.streamPay.recipientBalance(id));
  }

  /** micro-USDC the sender would reclaim on an immediate cancel. */
  async senderBalance(id) {
    return usdcAmount(await this.streamPay.senderBalance(id));
  }

  /** Decoded stream record + a live progress snapshot. */
  async getStream(id) {
    const [s, recip, sender] = await Promise.all([
      this.streamPay.get(id),
      this.streamPay.recipientBalance(id),
      this.streamPay.senderBalance(id),
    ]);
    const pct = s.deposit > 0n ? Number((s.withdrawn + recip) * 10000n / s.deposit) / 100 : 0;
    return {
      sender: s.sender,
      recipient: s.recipient,
      deposit: usdcAmount(s.deposit),
      withdrawn: usdcAmount(s.withdrawn),
      start: Number(s.start),
      stop: Number(s.stop),
      status: STREAM_STATUS[Number(s.status)] ?? "Unknown",
      withdrawable: usdcAmount(recip),
      reclaimable: usdcAmount(sender),
      streamedPct: pct,
    };
  }

  // --- misc ------------------------------------------------------------------

  /** Totals for the hub: obligations opened + streams opened. */
  async stats() {
    const [nextObl, nextStream] = await Promise.all([
      this.agentBond.nextObligationId(),
      this.streamPay.nextId(),
    ]);
    return { obligations: Number(nextObl) - 1, streams: Number(nextStream) - 1 };
  }

  explorerTx(hash) {
    return `${ARC.explorer}/tx/${hash}`;
  }

  /** Pull an id from the first matching event in a receipt. */
  _eventId(receipt, contract, eventName) {
    for (const log of receipt.logs) {
      try {
        const parsed = contract.interface.parseLog(log);
        if (parsed && parsed.name === eventName) return parsed.args.id;
      } catch {
        /* not our event */
      }
    }
    return undefined;
  }
}

export default ArcAgenticStack;
