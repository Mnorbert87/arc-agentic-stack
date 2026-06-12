# Sample run — cross-chain capital onboarding (real transactions)

`PRIVATE_KEY=0x… npm run onboard` · burner `0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a`
(same EOA on both chains) · amount **1.0 USDC** · Circle **Bridge Kit** (App Kit, CCTP V2, Fast
Transfer). Every tx below is confirmed (`status 1`).

## What happened

`1 USDC` left Base Sepolia and arrived on Arc as AgentBond collateral — the agent's bond capital
was onboarded cross-chain in one flow:

| Step | Chain | Tx | Block | Status |
|---|---|---|---|---|
| `depositForBurn` (burn) | Base Sepolia | [`0x6232b1…25d8`](https://sepolia.basescan.org/tx/0x6232b181d8f3234162f8d617ba5a5215b62eb9c902e5f70b0f6312cb0e8725d8) | 42757497 | ✅ 1 |
| `receiveMessage` (mint) | Arc | [`0xcae264…26d2b`](https://testnet.arcscan.app/tx/0xcae2649abaee2544144a7cedc73b38915ef62d2fce545b566168f30735326d2b) | 46754515 | ✅ 1 |
| `approve` USDC → AgentBond | Arc | [`0xdf7deb…9990`](https://testnet.arcscan.app/tx/0xdf7debad5e3641eb4c865b5b04faa4345ad37acc3f4ef2427d576c6309a09990) | 46754533 | ✅ 1 |
| `AgentBond.deposit(1 USDC)` | Arc | [`0xf17ca3…96bc`](https://testnet.arcscan.app/tx/0xf17ca3a4004b8b969cdb633d1d7f42703a7618f34a56092fc1e9b82eba5f96bc) | 46754533 | ✅ 1 |

**On-chain effect (verified):**
- Base Sepolia USDC balance: `20 → 19` (1 USDC burned).
- AgentBond bond for the agent: `36 → 37 USDC` — the bridged dollar is now slashable collateral.

## Console transcript

```
» burner 0x2e36F4037E711e1d4c853BBCBF7F526B3714A08a · onboarding 1.0 USDC  Base Sepolia → Arc
» estimate: {"token":"USDC","amount":"1.0",
    "source":{"chain":"Base_Sepolia"},"destination":{"chain":"Arc_Testnet"},
    "gasFees":[
      {"name":"Approve","token":"ETH","blockchain":"Base_Sepolia","fees":{"fee":"0.000000339126"}},
      {"name":"Burn","token":"ETH","blockchain":"Base_Sepolia","fees":{"fee":"0.0000012696075"}},
      {"name":"Mint","token":"USDC","blockchain":"Arc_Testnet","fees":{"fee":"0.004986359190923184"}}],
    "fees":[{"type":"provider","token":"USDC","amount":"0.000143"}]}
» kit.bridge(Base_Sepolia → Arc_Testnet, FAST) …
» bridged. source burn=0x6232b1…25d8  dest mint=0xcae264…26d2b
» AgentBond approve + deposit on Arc …
» AgentBond bond 36000000 → 37000000
» DONE — bridged capital deposited into AgentBond. result.json written.
```

Total cost: a few **micro-USDC** of CCTP provider fee (`0.000143`) + a fraction of a cent of gas.
Fast Transfer cleared in well under a minute on testnet. The agent's capital crossed chains and
became a slashable bond with no bridge in the trust path — just Circle CCTP V2 and USDC.
