# Brimdex LMSR + Conditional Tokens fork

Solidity **0.8.28** (Cancun, `viaIR`) under `LMSR/Brimdex/`: one CTF (ERC1155), one stack factory, **DIA Push Oracle** resolution.

## Layout

- `ct/` — **`BrimdexConditionalTokens`** (`registerMarket`, `bindMarketMaker`, **`resolve` only from the bound LMSR**), **`BrimdexAssetRegistry`**, **`IDIAOracleV2`** (`getValue`), **`CTHelpers`**.
- `lmsr/` — **`MarketMaker`** / **`LMSRMarketMaker`** (`tradeRouter` + `bootstrapExecutor`), **`BrimdexLMSRRouter`** (**`tradeLmsr` only**), **`BrimdexFeeConfig`**, **`BrimdexLMSRStackFactory`** (immutable **`collateralAsset`**, **`openMarket`** = register + deploy LMSR + **`bindMarketMaker`** + optional staking notifier + fund + bootstrap in **one** tx).
- `raise/` — **`BrimdexStackLaunchVault`** (commitments; at open reads DIA for `assetKey`, normalizes to **6 decimals** like **`resolve`**, sets **`lower`/`upper` = spot ± `bandBps`**, **`expiry = now + horizonSeconds`** (min 5 minutes); **`redeemCommitment`** after **`Aborted`**).
- `mocks/` — **`MockDIAPushOracle`**, **`MockERC20`**, **`MockVaultForE2E`** (test harness that pays `openMarket` and receives `receiveLP`).

## Flow

1. Registry owner: **`setFeed(assetKey, diaFeedKeyString)`** on **`assetRegistry`** (each `assetKey` is **immutable** after first set).
2. Factory owner: **`authorizeVault(vault)`** so the vault can call **`openMarket`**.
3. **`BrimdexLMSRStackFactory`** + **`createLaunchVault(..., horizonSeconds_, ...)`**. **`openMarket(..., launchOracleSpot6, launchBandBps, launchHorizonSeconds)`** — trailing launch fields are **telemetry** (vault passes `horizonSeconds`; direct opens pass **zeros**).
4. Trades: **`BrimdexLMSRRouter.tradeLmsr`** (ERC20 / ERC1155 approvals to the **LMSR** contract). Trades revert after **`expiryTimestamp`**.
5. After expiry: **`LMSRMarketMaker.resolve()`** pays resolver (≤3 USDC from protocol fees), calls **`BrimdexConditionalTokens.resolve`**, redeems, sends residual + LP fees to **`vault`**, closes the AMM.

## Compile & tests

```bash
npm run hh:compile:lmsr-brimdex
npm run test:lmsr-brimdex
```

Integration tests: `test/lmsr-brimdex.e2e.js` (DIA mock + vault + **11 wallets** + **`market.resolve`** + redeem). Writes **`test/lmsr-brimdex-run-report.json`** and **`test/lmsr-brimdex-run-summary.md`**. **`test/brimdex-stack-launch-vault.test.js`** covers raise → **`openCommittedMarket`**. Deploy **`Fixed192x64Math`** first for linking.

## Fees (LMSR)

- **`accruedLPFees`** / **`accruedProtocolFees`** on trades; **`withdrawFees()`** sends protocol share to **`feeConfig.protocolWallet()`**, keeping up to **3 USDC** reserved until the market is **`Closed`** (resolver tip).

## Staking (BDX)

- **`BDXStaking`**: owner sets **`setStackFactory(stackFactory)`** once; each new LMSR is **`authorizeRewardNotifier`**’d by the factory so markets can call **`notifyRewardAmount`**.

## Notes

- Add tests / review before production.
