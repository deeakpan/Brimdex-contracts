// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { OrderBookLinkedList } from "./OrderBookLinkedList.sol";
import { OrderPriceVolumeSet } from "./OrderPriceVolumeSet.sol";

/// @dev Slim views into `LMSRMarketMaker` — we never write through this interface, only sanity-check.
interface ILMSRMarketMakerView {
    function pmSystem() external view returns (address);
    function collateralToken() external view returns (address);
    function conditionIds(uint256 i) external view returns (bytes32);
    function expiryTimestamp() external view returns (uint256);
    /// @notice 0 = Running, 1 = Paused, 2 = Closed. Matches `LMSRMarketMaker.Stage`.
    function stage() external view returns (uint8);
}

/// @dev Slim view into `BrimdexConditionalTokens` — we use it both as the ERC-1155 share ledger
///      AND to derive the canonical `positionId` for each `(market, outcome)` pair.
interface IBrimdexCTF {
    function getCollectionId(
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256 indexSet
    ) external view returns (bytes32);

    function getPositionId(
        IERC20 collateralToken,
        bytes32 collectionId
    ) external pure returns (uint256);

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @title BrimdexCTFOrderBook
/// @notice On-chain CLOB for BREAK / BOUND outcome shares minted on `BrimdexConditionalTokens`.
/// @dev    Replaces the original `BrimdexOrderBook` which traded per-market ERC-20 BOUND/BREAK
///         tokens issued by `BrimdexFactory`. In the LMSR rewrite, every market's two outcomes
///         live as ERC-1155 balances on a single global CTF, keyed by `positionId` derived from
///         `conditionId` + index set. The orderbook now identifies a market+side by
///         `(LMSRMarketMaker, outcome)` and resolves the `positionId` once per pair on first use.
///
///         No minting — only transfers existing CTF shares between users. Matching is CLOB-style:
///         an incoming sell hits resting bids at >= limit (maker bid price); an incoming buy hits
///         resting asks at <= limit (maker ask price). Buyer and seller each pay `feeRate` bps on
///         matched notional. Logic ported 1:1 from the original orderbook so behaviour, fee math
///         and surplus refund are preserved.
contract BrimdexCTFOrderBook is Ownable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;
    using OrderBookLinkedList for OrderBookLinkedList.LinkedList;
    using OrderPriceVolumeSet for OrderPriceVolumeSet.OPVset;

    // ─── Immutables ─────────────────────────────────────────────────────────────

    /// @notice USDC (6-decimal collateral). Must match every market's `collateralToken()`.
    IERC20 public immutable collateralToken;
    /// @notice `BrimdexConditionalTokens` — the ERC-1155 ledger holding every outcome share.
    IBrimdexCTF public immutable ctf;
    /// @notice Receives all accumulated USDC fees via `withdrawFees` (immutable; set at deploy).
    address public immutable treasury;

    // ─── Outcome constants ──────────────────────────────────────────────────────

    /// @notice BREAK outcome — index set = 1 in the CTF (outcome slot 0 in binary markets).
    uint8 public constant OUTCOME_BREAK = 0;
    /// @notice BOUND outcome — index set = 2 in the CTF (outcome slot 1 in binary markets).
    uint8 public constant OUTCOME_BOUND = 1;

    // ─── Mutable config ─────────────────────────────────────────────────────────

    /// @notice Fee in basis points ( / 10_000 ) applied to EACH side on matched notional.
    uint16 public feeRate;
    uint256 public accumulatedFee;

    // ─── Orderbook storage (keyed by market + outcome instead of market + token) ─

    mapping(address => mapping(uint8 => mapping(uint256 => OrderBookLinkedList.LinkedList)))
        public sellOrderBook;
    mapping(address => mapping(uint8 => mapping(uint256 => OrderBookLinkedList.LinkedList)))
        public buyOrderBook;

    mapping(address => mapping(uint8 => OrderPriceVolumeSet.OPVset)) private _sellOrders;
    mapping(address => mapping(uint8 => OrderPriceVolumeSet.OPVset)) private _buyOrders;

    mapping(address => mapping(uint8 => uint256[])) private _sellPrices;
    mapping(address => mapping(uint8 => uint256[])) private _buyPrices;
    mapping(address => mapping(uint8 => mapping(uint256 => bool))) private _activePrices;

    /// @notice Cached CTF position id for `(market, outcome)` — populated on first interaction
    ///         so repeated trades against the same level pay one SLOAD instead of three external
    ///         calls + a `getPositionId` derivation.
    mapping(address => mapping(uint8 => uint256)) public positionIdOf;

    // ─── Events ─────────────────────────────────────────────────────────────────

    event OrderPlaced(
        address indexed market,
        uint8 indexed outcome,
        address indexed user,
        uint256 price,
        uint256 amount,
        bytes32 orderId,
        bool isBuy
    );

    event OrderMatched(
        address indexed market,
        uint8 indexed outcome,
        address indexed maker,
        address taker,
        uint256 price,
        uint256 amount
    );

    event OrderCancelled(
        address indexed market,
        uint8 indexed outcome,
        address indexed user,
        uint256 price,
        bytes32 orderId
    );

    event FeesWithdrawn(address indexed recipient, uint256 amount);
    event PositionIdCached(address indexed market, uint8 indexed outcome, uint256 positionId);

    // ─── Errors ─────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error OnlyTreasury();
    error InvalidOutcome();
    error MarketWrongCTF();
    error MarketWrongCollateral();
    error MarketNotRunning();
    error MarketExpired();
    error FeeTooHigh();
    error ZeroPrice();
    error ZeroAmount();

    // ─── Constructor ────────────────────────────────────────────────────────────

    constructor(
        address _ctf,
        address _collateralToken,
        address _owner,
        address _treasury
    ) Ownable(_owner) {
        if (
            _ctf == address(0) ||
            _collateralToken == address(0) ||
            _owner == address(0) ||
            _treasury == address(0)
        ) revert ZeroAddress();

        ctf = IBrimdexCTF(_ctf);
        collateralToken = IERC20(_collateralToken);
        treasury = _treasury;
        feeRate = 50; // 0.5% per side on matched notional (bps / 10_000)
    }

    // ─── Owner config ───────────────────────────────────────────────────────────

    /// @notice Set per-side fee in basis points (applied to buyer and seller on each match). Owner only.
    function setFeeRate(uint16 _feeRate) external onlyOwner {
        if (_feeRate > 1000) revert FeeTooHigh();
        feeRate = _feeRate;
    }

    // ─── Internal helpers (fee + escrow math, copied 1:1 from the original) ────

    /// @notice USDC escrow required to buy up to `tokenAmount` shares at `limitPrice` (notional + buyer-side fee reserve).
    function _escrowForBuy(uint256 tokenAmount, uint256 limitPrice) internal view returns (uint256) {
        uint256 maxNotional = (tokenAmount * limitPrice) / 1e6;
        return maxNotional + (maxNotional * feeRate) / 10000;
    }

    /// @notice USDC escrow the buyer pays for `matchTok` shares at `price` (same floor math as matching).
    function _buyerEscrowForTokens(
        uint256 matchTok,
        uint256 price,
        uint16 _feeRate
    ) internal pure returns (uint256) {
        uint256 n = (matchTok * price) / 1e6;
        return n + (n * _feeRate) / 10000;
    }

    /// @notice Largest `matchTok` in [0, cap] with `_buyerEscrowForTokens <= escrowLimit`.
    /// @dev Binary search — stacked floor divisions break the old "decrement at most once" assumption.
    function _maxMatchTokUnderEscrow(
        uint256 escrowLimit,
        uint256 price,
        uint256 cap,
        uint16 _feeRate
    ) internal pure returns (uint256) {
        if (cap == 0 || escrowLimit == 0 || price == 0) return 0;
        uint256 hi = cap;
        unchecked {
            uint256 mulCap = type(uint256).max / price;
            if (hi > mulCap) hi = mulCap;
        }
        uint256 lo = 0;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_buyerEscrowForTokens(mid, price, _feeRate) <= escrowLimit) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    /// @dev Validates that `market` is a live LMSR bound to our CTF + USDC and not past expiry,
    ///      then returns (and lazily caches) the CTF `positionId` for the `(market, outcome)` pair.
    ///      Reverts if outcome is not 0/1, market wires to a different CTF/collateral, is not
    ///      Running, or has already expired.
    function _validateAndResolvePosId(address market, uint8 outcome)
        internal
        returns (uint256 posId)
    {
        if (outcome > 1) revert InvalidOutcome();

        ILMSRMarketMakerView mm = ILMSRMarketMakerView(market);
        if (mm.pmSystem() != address(ctf)) revert MarketWrongCTF();
        if (mm.collateralToken() != address(collateralToken)) revert MarketWrongCollateral();
        if (mm.stage() != 0) revert MarketNotRunning();
        if (block.timestamp >= mm.expiryTimestamp()) revert MarketExpired();

        posId = positionIdOf[market][outcome];
        if (posId == 0) {
            bytes32 cond = mm.conditionIds(0);
            // BREAK = index set 1 (slot 0), BOUND = index set 2 (slot 1).
            uint256 indexSet = (outcome == OUTCOME_BREAK) ? 1 : 2;
            bytes32 collectionId = ctf.getCollectionId(bytes32(0), cond, indexSet);
            posId = ctf.getPositionId(collateralToken, collectionId);
            positionIdOf[market][outcome] = posId;
            emit PositionIdCached(market, outcome, posId);
        }
    }

    // ─── Place orders ───────────────────────────────────────────────────────────

    /// @notice Place a sell order for `amount` shares of `(market, outcome)` at `price` USDC/share (6dp).
    function placeSellOrder(
        address market,
        uint8 outcome,
        uint256 price,
        uint256 amount
    ) external nonReentrant returns (bytes32 orderId) {
        if (price == 0) revert ZeroPrice();
        if (amount == 0) revert ZeroAmount();

        uint256 posId = _validateAndResolvePosId(market, outcome);

        // Pull the shares into orderbook custody. We hold them until they fill or get cancelled.
        ctf.safeTransferFrom(msg.sender, address(this), posId, amount, "");

        uint256 remainingAmount = _matchSellOrder(market, outcome, posId, price, amount);

        if (remainingAmount > 0) {
            if (sellOrderBook[market][outcome][price].length == 0) {
                orderId = sellOrderBook[market][outcome][price].initHead(msg.sender, remainingAmount);
                _addSellPrice(market, outcome, price);
            } else {
                orderId = sellOrderBook[market][outcome][price].addNode(msg.sender, remainingAmount);
            }

            _sellOrders[market][outcome]._add(msg.sender, orderId, price, remainingAmount);
            emit OrderPlaced(market, outcome, msg.sender, price, remainingAmount, orderId, false);
        }
    }

    /// @notice Place a buy order for up to `amount` shares of `(market, outcome)` at limit `price`.
    function placeBuyOrder(
        address market,
        uint8 outcome,
        uint256 price,
        uint256 amount
    ) external nonReentrant returns (bytes32 orderId) {
        if (price == 0) revert ZeroPrice();
        if (amount == 0) revert ZeroAmount();

        uint256 posId = _validateAndResolvePosId(market, outcome);

        uint256 escrowTotal = _escrowForBuy(amount, price);
        collateralToken.safeTransferFrom(msg.sender, address(this), escrowTotal);

        (uint256 remainingTokens, uint256 escrowLeft) = _matchBuyOrder(
            market,
            outcome,
            posId,
            price,
            amount,
            escrowTotal
        );

        // Refund price-improvement surplus: fills at better prices leave excess escrow.
        uint256 escrowNeeded = remainingTokens > 0 ? _escrowForBuy(remainingTokens, price) : 0;
        if (escrowLeft > escrowNeeded) {
            collateralToken.safeTransfer(msg.sender, escrowLeft - escrowNeeded);
            escrowLeft = escrowNeeded;
        }

        if (remainingTokens > 0) {
            if (buyOrderBook[market][outcome][price].length == 0) {
                orderId = buyOrderBook[market][outcome][price].initHead(msg.sender, escrowLeft);
                _addBuyPrice(market, outcome, price);
            } else {
                orderId = buyOrderBook[market][outcome][price].addNode(msg.sender, escrowLeft);
            }

            _buyOrders[market][outcome]._add(msg.sender, orderId, price, escrowLeft);
            emit OrderPlaced(market, outcome, msg.sender, price, remainingTokens, orderId, true);
        }
    }

    // ─── Cancel orders ──────────────────────────────────────────────────────────
    //   No market state validation here so users can always reclaim escrowed funds
    //   even after the market resolves / closes.

    function cancelSellOrder(
        address market,
        uint8 outcome,
        uint256 price,
        bytes32 orderId
    ) external nonReentrant {
        OrderBookLinkedList.Order memory o =
            sellOrderBook[market][outcome][price].nodes[orderId].order;
        require(msg.sender == o.seller, "Not order owner");

        uint256 posId = positionIdOf[market][outcome];
        // posId is guaranteed non-zero here because the order could only have been placed
        // via `placeSellOrder` which populates the cache before recording the order.
        ctf.safeTransferFrom(address(this), msg.sender, posId, o.amount, "");

        sellOrderBook[market][outcome][price].deleteNode(orderId);
        _sellOrders[market][outcome]._remove(msg.sender, orderId);
        _removePrice(market, outcome, price, true);

        emit OrderCancelled(market, outcome, msg.sender, price, orderId);
    }

    function cancelBuyOrder(
        address market,
        uint8 outcome,
        uint256 price,
        bytes32 orderId
    ) external nonReentrant {
        OrderBookLinkedList.Order memory o =
            buyOrderBook[market][outcome][price].nodes[orderId].order;
        require(msg.sender == o.seller, "Not order owner");

        collateralToken.safeTransfer(msg.sender, o.amount);

        buyOrderBook[market][outcome][price].deleteNode(orderId);
        _buyOrders[market][outcome]._remove(msg.sender, orderId);
        _removePrice(market, outcome, price, false);

        emit OrderCancelled(market, outcome, msg.sender, price, orderId);
    }

    // ─── Matching engines ───────────────────────────────────────────────────────

    /// @notice Match incoming sell against resting bids at >= sellLimitPrice (FIFO per level).
    function _matchSellOrder(
        address market,
        uint8 outcome,
        uint256 posId,
        uint256 sellLimitPrice,
        uint256 sellAmount
    ) internal returns (uint256 remainingAmount) {
        remainingAmount = sellAmount;
        uint16 fr = feeRate;
        uint256[] memory bids = _loadSortedDesc(_buyPrices[market][outcome]);

        for (uint256 idx = 0; idx < bids.length && remainingAmount > 0; idx++) {
            uint256 bidPrice = bids[idx];
            if (bidPrice < sellLimitPrice) break;

            while (
                buyOrderBook[market][outcome][bidPrice].length > 0 && remainingAmount > 0
            ) {
                bytes32 head_ = buyOrderBook[market][outcome][bidPrice].head;
                uint256 buyEscrow =
                    buyOrderBook[market][outcome][bidPrice].nodes[head_].order.amount;
                OrderBookLinkedList.Order memory buyOrder =
                    buyOrderBook[market][outcome][bidPrice].nodes[head_].order;

                uint256 matchTok = _maxMatchTokUnderEscrow(buyEscrow, bidPrice, remainingAmount, fr);
                if (matchTok == 0) return remainingAmount;

                uint256 n = (matchTok * bidPrice) / 1e6;
                uint256 buyerFee = (n * fr) / 10000;
                uint256 sellerFee = (n * fr) / 10000;

                uint256 escrowDec = n + buyerFee;
                accumulatedFee += buyerFee + sellerFee;

                if (escrowDec >= buyEscrow) {
                    buyOrderBook[market][outcome][bidPrice].popHead();
                    _buyOrders[market][outcome]._remove(buyOrder.seller, head_);
                    _removePrice(market, outcome, bidPrice, false);
                } else {
                    buyOrderBook[market][outcome][bidPrice].nodes[head_].order.amount =
                        buyEscrow - escrowDec;
                    _buyOrders[market][outcome]._subVolume(buyOrder.seller, head_, escrowDec);
                }

                // Push shares from orderbook escrow to the buyer; pay seller in USDC net of fee.
                ctf.safeTransferFrom(address(this), buyOrder.seller, posId, matchTok, "");
                collateralToken.safeTransfer(msg.sender, n - sellerFee);

                emit OrderMatched(market, outcome, buyOrder.seller, msg.sender, bidPrice, matchTok);

                remainingAmount -= matchTok;
            }
        }
    }

    /// @notice Match incoming buy against resting asks at <= buyLimitPrice (FIFO per level).
    function _matchBuyOrder(
        address market,
        uint8 outcome,
        uint256 posId,
        uint256 buyLimitPrice,
        uint256 buyTokenAmount,
        uint256 buyerEscrowIn
    ) internal returns (uint256 remainingTokens, uint256 escrowOut) {
        remainingTokens = buyTokenAmount;
        escrowOut = buyerEscrowIn;
        uint16 fr = feeRate;
        uint256[] memory asks = _loadSortedAsc(_sellPrices[market][outcome]);

        for (
            uint256 idx = 0;
            idx < asks.length && remainingTokens > 0 && escrowOut > 0;
            idx++
        ) {
            uint256 askPrice = asks[idx];
            if (askPrice > buyLimitPrice) break;

            while (
                sellOrderBook[market][outcome][askPrice].length > 0 &&
                remainingTokens > 0 &&
                escrowOut > 0
            ) {
                bytes32 head_ = sellOrderBook[market][outcome][askPrice].head;
                uint256 sellTokAvail =
                    sellOrderBook[market][outcome][askPrice].nodes[head_].order.amount;
                OrderBookLinkedList.Order memory sellOrder =
                    sellOrderBook[market][outcome][askPrice].nodes[head_].order;

                uint256 cap = remainingTokens < sellTokAvail ? remainingTokens : sellTokAvail;
                uint256 matchTok = _maxMatchTokUnderEscrow(escrowOut, askPrice, cap, fr);
                if (matchTok == 0) return (remainingTokens, escrowOut);

                uint256 n = (matchTok * askPrice) / 1e6;
                uint256 buyerFee = (n * fr) / 10000;
                uint256 sellerFee = (n * fr) / 10000;

                uint256 escrowDec = n + buyerFee;
                accumulatedFee += buyerFee + sellerFee;
                escrowOut -= escrowDec;

                if (matchTok == sellTokAvail) {
                    sellOrderBook[market][outcome][askPrice].popHead();
                    _sellOrders[market][outcome]._remove(sellOrder.seller, head_);
                    _removePrice(market, outcome, askPrice, true);
                } else {
                    sellOrderBook[market][outcome][askPrice].nodes[head_].order.amount =
                        sellTokAvail - matchTok;
                    _sellOrders[market][outcome]._subVolume(sellOrder.seller, head_, matchTok);
                }

                // Push shares from orderbook escrow to taker (buyer); pay seller in USDC net of fee.
                ctf.safeTransferFrom(address(this), msg.sender, posId, matchTok, "");
                collateralToken.safeTransfer(sellOrder.seller, n - sellerFee);

                emit OrderMatched(market, outcome, sellOrder.seller, msg.sender, askPrice, matchTok);

                remainingTokens -= matchTok;
            }
        }
    }

    // ─── Price set management ───────────────────────────────────────────────────

    function _addSellPrice(address market, uint8 outcome, uint256 price) internal {
        if (!_activePrices[market][outcome][price]) {
            _activePrices[market][outcome][price] = true;
            _sellPrices[market][outcome].push(price);
        }
    }

    function _addBuyPrice(address market, uint8 outcome, uint256 price) internal {
        if (!_activePrices[market][outcome][price]) {
            _activePrices[market][outcome][price] = true;
            _buyPrices[market][outcome].push(price);
        }
    }

    function _removePrice(address market, uint8 outcome, uint256 price, bool isSell) internal {
        if (
            sellOrderBook[market][outcome][price].length == 0 &&
            buyOrderBook[market][outcome][price].length == 0
        ) {
            _activePrices[market][outcome][price] = false;
            if (isSell) {
                _removeFromArray(_sellPrices[market][outcome], price);
            } else {
                _removeFromArray(_buyPrices[market][outcome], price);
            }
        }
    }

    function _removeFromArray(uint256[] storage arr, uint256 price) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == price) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @dev Copy storage array to memory and insertion-sort descending. No SSTOREs.
    function _loadSortedDesc(uint256[] storage src) internal view returns (uint256[] memory arr) {
        arr = new uint256[](src.length);
        for (uint256 i = 0; i < src.length; i++) arr[i] = src[i];
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] < key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }

    /// @dev Copy storage array to memory and insertion-sort ascending. No SSTOREs.
    function _loadSortedAsc(uint256[] storage src) internal view returns (uint256[] memory arr) {
        arr = new uint256[](src.length);
        for (uint256 i = 0; i < src.length; i++) arr[i] = src[i];
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }

    // ─── Treasury ───────────────────────────────────────────────────────────────

    /// @notice Pull all accumulated USDC fees to `treasury`. Callable **only** by `treasury`.
    function withdrawFees() external nonReentrant {
        if (msg.sender != treasury) revert OnlyTreasury();
        uint256 fee = accumulatedFee;
        accumulatedFee = 0;
        if (fee > 0) {
            collateralToken.safeTransfer(treasury, fee);
        }
        emit FeesWithdrawn(treasury, fee);
    }

    // ─── View functions ─────────────────────────────────────────────────────────

    /// @notice Get best bid price (highest active bid) for `(market, outcome)`.
    function getBestBid(address market, uint8 outcome) external view returns (uint256 best) {
        uint256[] storage prices = _buyPrices[market][outcome];
        for (uint256 i = 0; i < prices.length; i++) {
            if (buyOrderBook[market][outcome][prices[i]].length > 0 && prices[i] > best) {
                best = prices[i];
            }
        }
    }

    /// @notice Get best ask price (lowest active ask) for `(market, outcome)`.
    function getBestAsk(address market, uint8 outcome) external view returns (uint256 best) {
        uint256[] storage prices = _sellPrices[market][outcome];
        for (uint256 i = 0; i < prices.length; i++) {
            if (
                sellOrderBook[market][outcome][prices[i]].length > 0 &&
                (best == 0 || prices[i] < best)
            ) {
                best = prices[i];
            }
        }
    }

    /// @notice All open sell orders for `user` on `(market, outcome)`.
    /// @dev volume = share amount remaining; price = ask limit price (USDC, 6dp).
    function getUserSellOrders(address market, uint8 outcome, address user)
        external
        view
        returns (OrderPriceVolumeSet.OPVnode[] memory)
    {
        return _sellOrders[market][outcome]._orders[user];
    }

    /// @notice All open buy orders for `user` on `(market, outcome)`.
    /// @dev volume = USDC escrow remaining; price = bid limit price (USDC, 6dp).
    function getUserBuyOrders(address market, uint8 outcome, address user)
        external
        view
        returns (OrderPriceVolumeSet.OPVnode[] memory)
    {
        return _buyOrders[market][outcome]._orders[user];
    }

    /// @notice Snapshot of the current order book — all active price levels with aggregated volume.
    /// @return bidPrices  Active bid (buy) price levels.
    /// @return bidVolumes Aggregated USDC escrow at each bid level (parallel array).
    /// @return askPrices  Active ask (sell) price levels.
    /// @return askVolumes Aggregated share volume at each ask level (parallel array).
    function getOrderBookSnapshot(address market, uint8 outcome)
        external
        view
        returns (
            uint256[] memory bidPrices,
            uint256[] memory bidVolumes,
            uint256[] memory askPrices,
            uint256[] memory askVolumes
        )
    {
        uint256[] storage bps = _buyPrices[market][outcome];
        uint256[] storage aps = _sellPrices[market][outcome];

        bidPrices = new uint256[](bps.length);
        bidVolumes = new uint256[](bps.length);
        askPrices = new uint256[](aps.length);
        askVolumes = new uint256[](aps.length);

        for (uint256 i = 0; i < bps.length; i++) {
            bidPrices[i] = bps[i];
            bytes32 curr = buyOrderBook[market][outcome][bps[i]].head;
            while (curr != bytes32(0)) {
                bidVolumes[i] += buyOrderBook[market][outcome][bps[i]].nodes[curr].order.amount;
                curr = buyOrderBook[market][outcome][bps[i]].nodes[curr].next;
            }
        }

        for (uint256 i = 0; i < aps.length; i++) {
            askPrices[i] = aps[i];
            bytes32 curr = sellOrderBook[market][outcome][aps[i]].head;
            while (curr != bytes32(0)) {
                askVolumes[i] += sellOrderBook[market][outcome][aps[i]].nodes[curr].order.amount;
                curr = sellOrderBook[market][outcome][aps[i]].nodes[curr].next;
            }
        }
    }

    /// @notice Returns the cached CTF position id for `(market, outcome)`, or 0 if not yet touched.
    function getPositionId(address market, uint8 outcome) external view returns (uint256) {
        return positionIdOf[market][outcome];
    }
}
