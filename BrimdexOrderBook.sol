// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OrderBookLinkedList} from "./libraries/OrderBookLinkedList.sol";
import {OrderPriceVolumeSet} from "./libraries/OrderPriceVolumeSet.sol";
import "./BrimdexFactory.sol";

/// @title BrimdexOrderBook
/// @notice Simple on-chain orderbook for trading BOUND/BREAK parimutuel tokens
/// @dev No minting - only transfers existing tokens between users.
///      Matching crosses price levels (CLOB-style): incoming sell hits bids at >= limit (maker bid price);
///      incoming buy hits asks at <= limit (maker ask price). Per-fill fees apply to buyer and seller (same bps).
///      Gas: `_insertSorted` / `_removeFromArray` are O(n) in the number of distinct price levels; fine early, costly at scale.
contract BrimdexOrderBook is Ownable {
    using SafeERC20 for IERC20;
    using OrderBookLinkedList for OrderBookLinkedList.LinkedList;
    using OrderPriceVolumeSet for OrderPriceVolumeSet.OPVset;

    IERC20 public immutable collateralToken; // USDC
    BrimdexFactory public immutable marketFactory;

    /// @notice Fee in basis points applied to **each side** on matched notional (buyer and seller each pay this rate).
    uint16 public feeRate;
    uint256 public accumulatedFee;

    // Order book: market => token => price => orders
    mapping(address => mapping(address => mapping(uint256 => OrderBookLinkedList.LinkedList)))
        public sellOrderBook;
    mapping(address => mapping(address => mapping(uint256 => OrderBookLinkedList.LinkedList)))
        public buyOrderBook;

    // User orders: market => token => user => [orders]
    mapping(address => mapping(address => OrderPriceVolumeSet.OPVset)) private _sellOrders;
    mapping(address => mapping(address => OrderPriceVolumeSet.OPVset)) private _buyOrders;

    // Active prices for efficient matching: market => token => prices[]
    mapping(address => mapping(address => uint256[])) private _sellPrices;
    mapping(address => mapping(address => uint256[])) private _buyPrices;
    mapping(address => mapping(address => mapping(uint256 => bool))) private _activePrices;

    // Events
    event OrderPlaced(
        address indexed market,
        address indexed token,
        address indexed user,
        uint256 price,
        uint256 amount,
        bytes32 orderId,
        bool isBuy
    );

    event OrderMatched(
        address indexed market,
        address indexed token,
        address indexed maker,
        address taker,
        uint256 price,
        uint256 amount
    );

    event OrderCancelled(
        address indexed market,
        address indexed token,
        address indexed user,
        uint256 price,
        bytes32 orderId
    );

    constructor(
        address _collateralToken,
        address _marketFactory,
        address _owner
    ) Ownable(_owner) {
        collateralToken = IERC20(_collateralToken);
        marketFactory = BrimdexFactory(_marketFactory);
        feeRate = 150; // 1.5% per side on matched notional
    }

    /// @notice Set per-side fee in basis points (applied to buyer and seller on each match).
    function setFeeRate(uint16 _feeRate) external onlyOwner {
        require(_feeRate <= 1000, "Fee too high");
        feeRate = _feeRate;
    }

    /// @notice USDC escrow required to buy up to `tokenAmount` tokens at `limitPrice` (notional + buyer-side fee reserve).
    function _escrowForBuy(uint256 tokenAmount, uint256 limitPrice) internal view returns (uint256) {
        uint256 maxNotional = (tokenAmount * limitPrice) / 1e6;
        return maxNotional + (maxNotional * feeRate) / 10000;
    }

    /// @notice Place a sell order
    /// @param market Market contract address
    /// @param token BOUND or BREAK token address
    /// @param price Price per token in USDC (6 decimals)
    /// @param amount Amount of tokens to sell
    function placeSellOrder(
        address market,
        address token,
        uint256 price,
        uint256 amount
    ) external returns (bytes32 orderId) {
        require(marketFactory.isMarket(market), "Invalid market");
        require(
            token == marketFactory.marketToBoundToken(market) ||
            token == marketFactory.marketToBreakToken(market),
            "Invalid token for market"
        );
        require(price > 0, "Price must be > 0");
        require(amount > 0, "Amount must be > 0");

        IERC20 tokenContract = IERC20(token);

        // Transfer tokens from user to this contract
        tokenContract.safeTransferFrom(msg.sender, address(this), amount);

        // Match against existing buy orders
        uint256 remainingAmount = _matchSellOrder(market, token, price, amount);

        // If not fully filled, add to order book
        if (remainingAmount > 0) {
            if (sellOrderBook[market][token][price].length == 0) {
                orderId = sellOrderBook[market][token][price].initHead(msg.sender, remainingAmount);
                _addSellPrice(market, token, price);
            } else {
                orderId = sellOrderBook[market][token][price].addNode(msg.sender, remainingAmount);
            }

            _sellOrders[market][token]._add(msg.sender, orderId, price, remainingAmount);
            emit OrderPlaced(market, token, msg.sender, price, remainingAmount, orderId, false);
        }
    }

    /// @notice Place a buy order
    /// @param market Market contract address
    /// @param token BOUND or BREAK token address
    /// @param price Price per token in USDC (6 decimals)
    /// @param amount Amount of tokens to buy
    function placeBuyOrder(
        address market,
        address token,
        uint256 price,
        uint256 amount
    ) external returns (bytes32 orderId) {
        require(marketFactory.isMarket(market), "Invalid market");
        require(
            token == marketFactory.marketToBoundToken(market) ||
            token == marketFactory.marketToBreakToken(market),
            "Invalid token for market"
        );
        require(price > 0, "Price must be > 0");
        require(amount > 0, "Amount must be > 0");

        uint256 escrowTotal = _escrowForBuy(amount, price);
        collateralToken.safeTransferFrom(msg.sender, address(this), escrowTotal);

        (uint256 remainingTokens, uint256 escrowLeft) = _matchBuyOrder(
            market,
            token,
            price,
            amount,
            escrowTotal
        );

        if (remainingTokens > 0) {
            require(escrowLeft >= _escrowForBuy(remainingTokens, price), "Insufficient escrow for remainder");

            if (buyOrderBook[market][token][price].length == 0) {
                orderId = buyOrderBook[market][token][price].initHead(msg.sender, escrowLeft);
                _addBuyPrice(market, token, price);
            } else {
                orderId = buyOrderBook[market][token][price].addNode(msg.sender, escrowLeft);
            }

            _buyOrders[market][token]._add(msg.sender, orderId, price, escrowLeft);
            emit OrderPlaced(market, token, msg.sender, price, remainingTokens, orderId, true);
        }
    }

    /// @notice Cancel a sell order
    function cancelSellOrder(
        address market,
        address token,
        uint256 price,
        bytes32 orderId
    ) external {
        OrderBookLinkedList.Order memory o = sellOrderBook[market][token][price]
            .nodes[orderId]
            .order;
        require(msg.sender == o.seller, "Not order owner");

        IERC20(token).safeTransfer(msg.sender, o.amount);

        sellOrderBook[market][token][price].deleteNode(orderId);
        _sellOrders[market][token]._remove(msg.sender, orderId);
        _removePrice(market, token, price, true);

        emit OrderCancelled(market, token, msg.sender, price, orderId);
    }

    /// @notice Cancel a buy order
    function cancelBuyOrder(
        address market,
        address token,
        uint256 price,
        bytes32 orderId
    ) external {
        OrderBookLinkedList.Order memory o = buyOrderBook[market][token][price]
            .nodes[orderId]
            .order;
        require(msg.sender == o.seller, "Not order owner");

        collateralToken.safeTransfer(msg.sender, o.amount);

        buyOrderBook[market][token][price].deleteNode(orderId);
        _buyOrders[market][token]._remove(msg.sender, orderId);
        _removePrice(market, token, price, false);

        emit OrderCancelled(market, token, msg.sender, price, orderId);
    }

    /// @notice Match incoming sell against resting bids at >= `sellLimitPrice` (FIFO per level). Executes at **maker bid** price.
    function _matchSellOrder(
        address market,
        address token,
        uint256 sellLimitPrice,
        uint256 sellAmount
    ) internal returns (uint256 remainingAmount) {
        remainingAmount = sellAmount;
        IERC20 tokenContract = IERC20(token);
        uint256[] storage bids = _buyPrices[market][token];

        for (uint256 idx = 0; idx < bids.length && remainingAmount > 0; idx++) {
            uint256 bidPrice = bids[idx];
            if (bidPrice < sellLimitPrice) break;

            while (buyOrderBook[market][token][bidPrice].length > 0 && remainingAmount > 0) {
                bytes32 head_ = buyOrderBook[market][token][bidPrice].head;
                uint256 buyEscrow = buyOrderBook[market][token][bidPrice].nodes[head_].order.amount;
                OrderBookLinkedList.Order memory buyOrder = buyOrderBook[market][token][bidPrice]
                    .nodes[head_]
                    .order;

                uint256 maxNotional = (buyEscrow * 10000) / (10000 + feeRate);
                uint256 maxBuyTokens = (maxNotional * 1e6) / bidPrice;
                // Cannot skip past FIFO head; dust at best bid blocks deeper matches.
                if (maxBuyTokens == 0) return remainingAmount;

                uint256 matchTok = remainingAmount < maxBuyTokens ? remainingAmount : maxBuyTokens;
                uint256 n = (matchTok * bidPrice) / 1e6;
                uint256 buyerFee = (n * feeRate) / 10000;
                uint256 sellerFee = (n * feeRate) / 10000;
                while (matchTok > 0 && n + buyerFee > buyEscrow) {
                    matchTok--;
                    n = (matchTok * bidPrice) / 1e6;
                    buyerFee = (n * feeRate) / 10000;
                    sellerFee = (n * feeRate) / 10000;
                }
                if (matchTok == 0) return remainingAmount;

                uint256 escrowDec = n + buyerFee;
                accumulatedFee += buyerFee + sellerFee;

                if (escrowDec >= buyEscrow) {
                    buyOrderBook[market][token][bidPrice].popHead();
                    _buyOrders[market][token]._remove(buyOrder.seller, head_);
                    _removePrice(market, token, bidPrice, false);
                } else {
                    buyOrderBook[market][token][bidPrice].nodes[head_].order.amount = buyEscrow - escrowDec;
                    _buyOrders[market][token]._subVolume(buyOrder.seller, head_, escrowDec);
                }

                tokenContract.safeTransfer(buyOrder.seller, matchTok);
                collateralToken.safeTransfer(msg.sender, n - sellerFee);

                emit OrderMatched(market, token, buyOrder.seller, msg.sender, bidPrice, matchTok);

                remainingAmount -= matchTok;
            }
        }
    }

    /// @notice Match incoming buy against resting asks at <= `buyLimitPrice` (FIFO per level). Executes at **maker ask** price.
    function _matchBuyOrder(
        address market,
        address token,
        uint256 buyLimitPrice,
        uint256 buyTokenAmount,
        uint256 buyerEscrowIn
    ) internal returns (uint256 remainingTokens, uint256 escrowOut) {
        remainingTokens = buyTokenAmount;
        escrowOut = buyerEscrowIn;
        IERC20 tokenContract = IERC20(token);
        uint256[] storage asks = _sellPrices[market][token];

        for (uint256 idx = 0; idx < asks.length && remainingTokens > 0 && escrowOut > 0; idx++) {
            uint256 askPrice = asks[idx];
            if (askPrice > buyLimitPrice) break;

            while (sellOrderBook[market][token][askPrice].length > 0 && remainingTokens > 0 && escrowOut > 0) {
                bytes32 head_ = sellOrderBook[market][token][askPrice].head;
                uint256 sellTokAvail = sellOrderBook[market][token][askPrice].nodes[head_].order.amount;
                OrderBookLinkedList.Order memory sellOrder = sellOrderBook[market][token][askPrice]
                    .nodes[head_]
                    .order;

                uint256 maxNotional = (escrowOut * 10000) / (10000 + feeRate);
                uint256 maxTokFromEscrow = (maxNotional * 1e6) / askPrice;
                uint256 matchTok = remainingTokens < sellTokAvail ? remainingTokens : sellTokAvail;
                if (maxTokFromEscrow < matchTok) matchTok = maxTokFromEscrow;
                if (matchTok == 0) {
                    return (remainingTokens, escrowOut);
                }

                uint256 n = (matchTok * askPrice) / 1e6;
                uint256 buyerFee = (n * feeRate) / 10000;
                uint256 sellerFee = (n * feeRate) / 10000;
                while (matchTok > 0 && n + buyerFee > escrowOut) {
                    matchTok--;
                    n = (matchTok * askPrice) / 1e6;
                    buyerFee = (n * feeRate) / 10000;
                    sellerFee = (n * feeRate) / 10000;
                }
                if (matchTok == 0) {
                    return (remainingTokens, escrowOut);
                }

                uint256 escrowDec = n + buyerFee;
                accumulatedFee += buyerFee + sellerFee;
                escrowOut -= escrowDec;

                if (matchTok == sellTokAvail) {
                    sellOrderBook[market][token][askPrice].popHead();
                    _sellOrders[market][token]._remove(sellOrder.seller, head_);
                    _removePrice(market, token, askPrice, true);
                } else {
                    sellOrderBook[market][token][askPrice].nodes[head_].order.amount = sellTokAvail - matchTok;
                    _sellOrders[market][token]._subVolume(sellOrder.seller, head_, matchTok);
                }

                tokenContract.safeTransfer(msg.sender, matchTok);
                collateralToken.safeTransfer(sellOrder.seller, n - sellerFee);

                emit OrderMatched(market, token, sellOrder.seller, msg.sender, askPrice, matchTok);

                remainingTokens -= matchTok;
            }
        }
    }

    /// @notice Add price to sorted list
    function _addSellPrice(address market, address token, uint256 price) internal {
        if (!_activePrices[market][token][price]) {
            _activePrices[market][token][price] = true;
            _insertSorted(_sellPrices[market][token], price, true);
        }
    }

    function _addBuyPrice(address market, address token, uint256 price) internal {
        if (!_activePrices[market][token][price]) {
            _activePrices[market][token][price] = true;
            _insertSorted(_buyPrices[market][token], price, false);
        }
    }

    function _removePrice(address market, address token, uint256 price, bool isSell) internal {
        if (sellOrderBook[market][token][price].length == 0 && 
            buyOrderBook[market][token][price].length == 0) {
            _activePrices[market][token][price] = false;
            if (isSell) {
                _removeFromArray(_sellPrices[market][token], price);
            } else {
                _removeFromArray(_buyPrices[market][token], price);
            }
        }
    }

    /// @dev O(n) shift insert; number of steps scales with distinct price levels on that side.
    function _insertSorted(uint256[] storage arr, uint256 price, bool ascending) internal {
        uint256 i = 0;
        while (i < arr.length && (ascending ? arr[i] < price : arr[i] > price)) {
            i++;
        }
        arr.push(0);
        for (uint256 j = arr.length - 1; j > i; j--) {
            arr[j] = arr[j - 1];
        }
        arr[i] = price;
    }

    /// @dev O(n) scan; same gas scaling as price-level count.
    function _removeFromArray(uint256[] storage arr, uint256 price) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == price) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @notice Get best bid price
    function getBestBid(address market, address token) external view returns (uint256) {
        uint256[] storage prices = _buyPrices[market][token];
        if (prices.length == 0) return 0;
        for (uint256 i = 0; i < prices.length; i++) {
            if (buyOrderBook[market][token][prices[i]].length > 0) {
                return prices[i];
            }
        }
        return 0;
    }

    /// @notice Get best ask price
    function getBestAsk(address market, address token) external view returns (uint256) {
        uint256[] storage prices = _sellPrices[market][token];
        if (prices.length == 0) return 0;
        for (uint256 i = 0; i < prices.length; i++) {
            if (sellOrderBook[market][token][prices[i]].length > 0) {
                return prices[i];
            }
        }
        return 0;
    }

    /// @notice Collect fees
    function collectFees() external onlyOwner {
        uint256 fee = accumulatedFee;
        accumulatedFee = 0;
        collateralToken.safeTransfer(owner(), fee);
    }
}
