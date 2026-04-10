# Contract README

`smart-contract` contains the project contract set.

## Flow summary

1. Deploy `BrimdexFactory`.
2. Deploy `OrderBookLinkedList` library.
3. Deploy `BrimdexOrderBook` with the linked library.
4. Deploy `BrimdexRouter`.
5. Create markets through factory.

## Seed LP model

- Per-market `MarketLiquidityVault`
- Non-transferable internal shares
- Fee streaming to vault
- Principal returned on settlement
- LP exits through `exit()` after settlement
