/**
 * Cross-chain capital onboarding for agents — Circle App Kit (Bridge Kit, CCTP V2).
 *
 * An agent's bond capital starts on Base Sepolia and is bridged to Arc with Circle's
 * official Bridge Kit (the App Kit suite, CCTPv2 under the hood), then deposited straight
 * into AgentBond on Arc. Bridge Kit lists Arc Testnet natively (chainId 5042002, CCTP
 * domain 26), so the whole cross-chain leg is one `kit.bridge()` call — no raw
 * depositForBurn / attestation polling / receiveMessage by hand.
 *
 *   [Base Sepolia]  ──kit.bridge(FAST)──▶  [Arc]  ──AgentBond.deposit──▶  bonded capital
 *
 * Run:  PRIVATE_KEY=0x<burner> npm run onboard
 *       (burner 0x2e36..A08a — same EOA on both chains; NEVER a personal key)
 *
 * Prereq: fund the burner on Base Sepolia (USDC via faucet.circle.com + a little ETH gas).
 *         Arc-side gas is USDC and the burner already holds it.
 */
import { BridgeKit } from '@circle-fin/bridge-kit'
import { createViemAdapterFromPrivateKey } from '@circle-fin/adapter-viem-v2'
import {
  createWalletClient, createPublicClient, http, defineChain, getAddress,
  encodeFunctionData, erc20Abi, parseUnits,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { writeFileSync } from 'node:fs'

const PRIVATE_KEY = (process.env.PRIVATE_KEY || process.env.DEPLOYER_PRIVATE_KEY) as `0x${string}`
if (!PRIVATE_KEY) throw new Error('set PRIVATE_KEY (burner) — never a personal key')
const AMOUNT = process.env.AMOUNT || '1.0' // USDC to onboard

// Arc testnet — USDC is the native gas token (18-dec native / 6-dec ERC-20 at 0x3600..0000)
const arc = defineChain({
  id: 5042002,
  name: 'Arc Testnet',
  nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.arc.network'] } },
  blockExplorers: { default: { name: 'Arcscan', url: 'https://testnet.arcscan.app' } },
})
const USDC_ARC = getAddress('0x3600000000000000000000000000000000000000')
const AGENT_BOND = getAddress('0xB9b4d476bC383eE2951a3eC3A22779458cdBf8e0')
const agentBondAbi = [
  { type: 'function', name: 'deposit', stateMutability: 'nonpayable', inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'bond', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
] as const

const account = privateKeyToAccount(PRIVATE_KEY)
const stepTx = (steps: any[], name: string) =>
  steps?.find((s) => s.name === name || s.type === name)?.txHash ?? steps?.find((s) => (s.name || '').toLowerCase().includes(name.toLowerCase()))?.txHash

async function main() {
  console.log(`» burner ${account.address} · onboarding ${AMOUNT} USDC  Base Sepolia → Arc`)

  // ── 1) cross-chain bridge via Circle Bridge Kit (CCTPv2, Fast Transfer) ──
  const kit = new BridgeKit()
  const adapter = createViemAdapterFromPrivateKey({ privateKey: PRIVATE_KEY })

  try {
    const est = await kit.estimate({
      from: { adapter, chain: 'Base_Sepolia' }, to: { adapter, chain: 'Arc_Testnet' },
      amount: AMOUNT, config: { transferSpeed: 'FAST' },
    })
    console.log('» estimate:', JSON.stringify(est, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)))
  } catch (e) { console.log('» estimate skipped:', (e as Error).message) }

  console.log('» kit.bridge(Base_Sepolia → Arc_Testnet, FAST) …')
  const result = await kit.bridge({
    from: { adapter, chain: 'Base_Sepolia' },
    to: { adapter, chain: 'Arc_Testnet' },
    amount: AMOUNT,
    config: { transferSpeed: 'FAST' },
  })
  const burnTx = stepTx(result.steps, 'depositForBurn') || stepTx(result.steps, 'burn')
  const mintTx = stepTx(result.steps, 'mint') || stepTx(result.steps, 'receiveMessage')
  console.log(`» bridged. source burn=${burnTx}  dest mint=${mintTx}`)

  // ── 2) Arc: the bridged capital becomes the agent's bond ──
  const pub = createPublicClient({ chain: arc, transport: http() })
  const wallet = createWalletClient({ account, chain: arc, transport: http() })
  const amountUnits = parseUnits(AMOUNT, 6) // USDC ERC-20 has 6 decimals on Arc

  const bondBefore = await pub.readContract({ address: AGENT_BOND, abi: agentBondAbi, functionName: 'bond', args: [account.address] })
  console.log('» AgentBond approve + deposit on Arc …')
  const approveTx = await wallet.sendTransaction({
    to: USDC_ARC, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [AGENT_BOND, amountUnits] }),
  })
  await pub.waitForTransactionReceipt({ hash: approveTx })
  const depositTx = await wallet.sendTransaction({
    to: AGENT_BOND, data: encodeFunctionData({ abi: agentBondAbi, functionName: 'deposit', args: [amountUnits] }),
  })
  await pub.waitForTransactionReceipt({ hash: depositTx })
  const bondAfter = await pub.readContract({ address: AGENT_BOND, abi: agentBondAbi, functionName: 'bond', args: [account.address] })
  console.log(`» AgentBond bond ${bondBefore} → ${bondAfter}`)

  // ── result map ──
  const out = {
    amount_usdc: AMOUNT,
    burner: account.address,
    sdk: '@circle-fin/bridge-kit (App Kit, CCTPv2)',
    base_sepolia: { depositForBurn: burnTx, explorer: `https://sepolia.basescan.org/tx/${burnTx}` },
    arc: {
      receiveMessage_mint: mintTx, explorer_mint: `https://testnet.arcscan.app/tx/${mintTx}`,
      agentbond_approve: approveTx, agentbond_deposit: depositTx,
      explorer_deposit: `https://testnet.arcscan.app/tx/${depositTx}`,
      bond_before: bondBefore.toString(), bond_after: bondAfter.toString(),
    },
  }
  writeFileSync(new URL('./result.json', import.meta.url), JSON.stringify(out, null, 2))
  console.log('» DONE — bridged capital deposited into AgentBond. result.json written.')
}
main().catch((e) => { console.error('✗ failed:', e); process.exit(1) })
