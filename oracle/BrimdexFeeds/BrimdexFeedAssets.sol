// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title BrimdexFeedAssets
/// @notice DIA keys and public DIA HTTP URLs per `assetId` (shared by oracle, coordinator, pullers).
library BrimdexFeedAssets {
    error BadAsset();

    uint8 public constant ASSET_COUNT = 16;

    /// @dev `assetKey` is `keccak256(bytes(diaKey))` (see `BrimdexAssetRegistry`).
    function assetIdForAssetKey(bytes32 assetKey) external pure returns (uint8) {
        for (uint8 i = 0; i < ASSET_COUNT; ++i) {
            if (keccak256(bytes(diaKeyOf(i))) == assetKey) {
                return i;
            }
        }
        revert BadAsset();
    }

    function diaKeyOf(uint8 assetId) internal pure returns (string memory) {
        if (assetId == 0) return "BTC/USD";
        if (assetId == 1) return "ETH/USD";
        if (assetId == 2) return "SOL/USD";
        if (assetId == 3) return "XAU/USD";
        if (assetId == 4) return "TSLA/USD";
        if (assetId == 5) return "AAPL/USD";
        if (assetId == 6) return "NVDA/USD";
        if (assetId == 7) return "WTI/USD";
        if (assetId == 8) return "MSFT/USD";
        if (assetId == 9) return "GOOGL/USD";
        if (assetId == 10) return "AMZN/USD";
        if (assetId == 11) return "META/USD";
        if (assetId == 12) return "XAG/USD";
        if (assetId == 13) return "NFLX/USD";
        if (assetId == 14) return "AMD/USD";
        if (assetId == 15) return "SPY/USD";
        revert BadAsset();
    }

    function feedUrl(uint8 assetId) internal pure returns (string memory) {
        if (assetId == 0) {
            return "https://api.diadata.org/v1/assetQuotation/Bitcoin/0x0000000000000000000000000000000000000000";
        }
        if (assetId == 1) {
            return "https://api.diadata.org/v1/assetQuotation/Ethereum/0x0000000000000000000000000000000000000000";
        }
        if (assetId == 2) {
            return "https://api.diadata.org/v1/assetQuotation/Solana/0x0000000000000000000000000000000000000000";
        }
        if (assetId == 3) {
            return "https://api.diadata.org/v1/rwa/Commodities/XAU-USD";
        }
        if (assetId == 4) {
            return "https://api.diadata.org/v1/rwa/Equities/TSLA";
        }
        if (assetId == 5) {
            return "https://api.diadata.org/v1/rwa/Equities/AAPL";
        }
        if (assetId == 6) {
            return "https://api.diadata.org/v1/rwa/Equities/NVDA";
        }
        if (assetId == 7) {
            return "https://api.diadata.org/v1/rwa/Commodities/WTI-USD";
        }
        if (assetId == 8) {
            return "https://api.diadata.org/v1/rwa/Equities/MSFT";
        }
        if (assetId == 9) {
            return "https://api.diadata.org/v1/rwa/Equities/GOOGL";
        }
        if (assetId == 10) {
            return "https://api.diadata.org/v1/rwa/Equities/AMZN";
        }
        if (assetId == 11) {
            return "https://api.diadata.org/v1/rwa/Equities/META";
        }
        if (assetId == 12) {
            return "https://api.diadata.org/v1/rwa/Commodities/XAG-USD";
        }
        if (assetId == 13) {
            return "https://api.diadata.org/v1/rwa/Equities/NFLX";
        }
        if (assetId == 14) {
            return "https://api.diadata.org/v1/rwa/Equities/AMD";
        }
        if (assetId == 15) {
            return "https://api.diadata.org/v1/rwa/Equities/SPY";
        }
        revert BadAsset();
    }
}
