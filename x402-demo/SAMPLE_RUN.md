# Sample run — verified on Arc Testnet (2026-06-09)

Real transcript of `./run.sh`. Every tx below is live on Arc Testnet and clickable on
[arcscan](https://testnet.arcscan.app). Buyer agent `0x2e36…A08a`, x402 server (payee)
`0x0D09cA4F24CF66206f66DA1dc200d213327EEbDc`, StreamPay `0x5057…2450`, stream **#14**.

```
[1/4] CALL — hitting http://localhost:4021/inference with no payment
   ← HTTP 402 Payment Required
     scheme=streampay asset=USDC payTo=0x0D09cA4F24CF66206f66DA1dc200d213327EEbDc

[2/4] PAY — opening a StreamPay stream: $0.300000 over 60s -> 0x0D09…EbDc
   ✓ createStream  gas ≈ $0.003289  /tx/0x771131299c5a876c8d008303409f4bd853968bd92306516098f29716e7671572
   stream #14 flowing at $0.005000/s

[3/4] CONSUME — paid calls (server settles per call from the stream)
   call 1: 200 — settled $0.045000  /tx/0x96f8a1a1fe0d11d883110830304ddbe5a5203c644f8d021d018eb0234fafb8e8
   call 2: 200 — settled $0.040000  /tx/0x9260c636ed09d64555f56143f2a52854daf9d12a4ab241c714fa5c67be2ee01f
   call 3: 200 — settled $0.045000  /tx/0x4778347679a23124f5f1bb0bffe5ecf0e90486778a50eed34f096cfb7e2d6c40

[4/4] SETTLE — cancelling the stream to reclaim the unspent budget
   reclaimable (unused budget): $0.130000
   ✓ cancel stream #14  gas ≈ $0.001803  /tx/0x0cfeae533d89cfee2f2d82ca2fcae08ab802da3668fee68919f3164ebd9eb358

✅ done. Paid per call, on-chain, autonomously.
   The 402→200 gate was bound to a live StreamPay settlement on Arc.
```

## Transaction index (Arc Testnet)

| Step | Tx | Explorer |
|------|----|----------|
| createStream (#14, 0.30 USDC / 60s) | `0x771131…671572` | https://testnet.arcscan.app/tx/0x771131299c5a876c8d008303409f4bd853968bd92306516098f29716e7671572 |
| call 1 settled $0.045 | `0x96f8a1…fafb8e8` | https://testnet.arcscan.app/tx/0x96f8a1a1fe0d11d883110830304ddbe5a5203c644f8d021d018eb0234fafb8e8 |
| call 2 settled $0.040 | `0x9260c6…2ee01f` | https://testnet.arcscan.app/tx/0x9260c636ed09d64555f56143f2a52854daf9d12a4ab241c714fa5c67be2ee01f |
| call 3 settled $0.045 | `0x477834…2d6c40` | https://testnet.arcscan.app/tx/0x4778347679a23124f5f1bb0bffe5ecf0e90486778a50eed34f096cfb7e2d6c40 |
| cancel — reclaim 0.13 USDC | `0x0cfeae…d9eb358` | https://testnet.arcscan.app/tx/0x0cfeae533d89cfee2f2d82ca2fcae08ab802da3668fee68919f3164ebd9eb358 |

The agent committed a 0.30 USDC budget, paid 0.17 USDC for the three calls it actually
made, and reclaimed the unused 0.13 USDC by cancelling — pay only for what you use.
