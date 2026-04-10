# Smart Contract Directory

This directory contains the project smart contracts.

## What is inside

- Core contracts: `BrimdexFactory.sol`, `BrimdexMarket.sol`, `BrimdexRouter.sol`, `BrimdexOrderBook.sol`
- Support contracts: `BrimdexParimutuelToken.sol`, `BrimdexFeeds.sol`, `MarketLiquidityVault.sol`, `IDataStreams.sol`
- Libraries: `libraries/OrderBookLinkedList.sol`, `libraries/OrderPriceVolumeSet.sol`
- Contract docs: `BRIMDEX_PARIMUTUEL_README.md`
- Deployment script: `scripts/deploy.cjs`

## Notes

- This is your contracts workspace.
- Contract deployment is handled by `scripts/deploy.cjs`.

## Deploy script

Run from project root:

`hardhat run --network somniaTestnet smart-contract/scripts/deploy.cjs`

Required environment variables:

- `USDC_ADDRESS`
- `PRICE_FEED_REGISTRY_ADDRESS` (or `FEEDS_ADDRESS`)

Optional:

- `TREASURY_ADDRESS`
- `DATA_STREAMS_ADDRESS`
- `PURCHASE_SCHEMA_ID`
