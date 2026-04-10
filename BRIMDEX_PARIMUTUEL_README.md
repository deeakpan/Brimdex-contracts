# BrimDex Parimutuel System

## Architecture

### Core Contracts

1. **BrimdexParimutuelMarket.sol** - Main market contract
   - `buyBound()` / `buyBreak()` - Users buy tokens; **2% trade fee** (180 bps treasury, 20 bps seed LPs); net USDC updates pools
   - `settle()` - Oracle reports outcome, calculates redemption rate (no % fee skim on trader pool in the normal case)
   - `redeem()` - Users redeem winning tokens for USDC
   - **Public seed:** per-market `MarketLiquidityVault` — LPs `deposit` USDC, factory `finalizeSeedMarket` moves seed into pools (50/50). Streaming 20 bps trade fees accrue via `accRewardPerShare`; principal + fees returned to vault at settlement; LPs call `exit()` once.

2. **BrimdexParimutuelOrderBook.sol** - Secondary market for early exits
   - `placeSellOrder()` - Sell tokens to other users
   - `placeBuyOrder()` - Buy tokens from other users
   - Simple matching, no minting (just transfers)
   - Per-market isolation

3. **BrimdexParimutuelToken.sol** - ERC20 tokens (BOUND/BREAK)
   - Mintable by market
   - Burnable on redemption
   - 6 decimals (same as USDC)

4. **BrimdexParimutuelMarketFactory.sol** - Creates markets
   - Deploys tokens + market
   - Sets up ownership
   - Registers markets

## How It Works

### Primary Market (Parimutuel)

**Buying:**
```
User: buyBound($100)
→ Price calculated: boundPool / (boundPool + breakPool)
→ Tokens minted: $100 / price
→ Pool updates: boundPool += $100
→ Price updates automatically
```

**Settlement:**
```
Oracle: Price = $3050 (within range)
→ BOUND wins
→ Redemption rate = winnings / totalBOUNDSupply
→ Users redeem tokens for USDC
```

### Secondary Market (OrderBook)

**Early Exit:**
```
Alice: placeSellOrder(200 BOUND @ $0.40)
Bob: placeBuyOrder(200 BOUND @ $0.40)
→ Match! Transfer tokens + USDC
→ Alice exits early, Bob holds until settlement
```

## Key Features

- ✅ Instant execution (parimutuel always accepts buys)
- ✅ Dynamic pricing (updates with each trade)
- ✅ Early exit option (orderbook)
- ✅ Optional public seed LPs (per-market vault, non-transferable shares)
- ✅ Per-market isolation
- ✅ Simple contracts (~200 lines each)

## Seed liquidity

1. Factory `createMarket` deploys the market + `MarketLiquidityVault` (pending, not yet on `markets[]`).
2. LPs `deposit` USDC until `factory.seedPrincipal()` is collected; owner calls `finalizeSeedMarket(market)` to fund the market and run `initialize`.
3. **0.2%** of each primary buy is **streamed** to the liquidity vault (`accRewardPerShare`); **principal** returns to the vault at settlement.
4. LPs use **`exit()`** after settlement (one tx: pending fees + pro-rata principal). Internal **non-transferable** shares (`sharesOf` / `totalShares`).
5. Oracle: prices older than **5 minutes** revert at `initialize` and `settle()`.

## Fees

- **Parimutuel (primary):** 2% **per buy** — 1.8% to immutable `treasury`, 0.2% streamed to the market’s `MarketLiquidityVault` each trade
- **Orderbook:** **1.5% per side** on matched notional (buyer escrow pays notional + buyer fee; seller receives notional − seller fee). Matches cross price levels at the **resting order’s price** (maker).
