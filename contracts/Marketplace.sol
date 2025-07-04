//SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/*
 __  __            _        _     ____  _                
|  \/  | __ _ _ __| | _____| |_  |  _ \| | __ _  ___ ___ 
| |\/| |/ _` | '__| |/ / _ \ __| | |_) | |/ _` |/ __/ _ \
| |  | | (_| | |  |   <  __/ |_  |  __/| | (_| | (_|  __/
|_|  |_|\__,_|_|  |_|\_\___|\__| |_|   |_|\__,_|\___\___|

*/

pragma solidity 0.8.28;

contract MarketPlace is Ownable, ReentrancyGuard, EIP712, Pausable {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    enum AssetType {
        ERC20,
        ERC721,
        ERC1155
    }

    bytes32 public constant EXCHANGE_TYPEHASH = keccak256(
        "Order("
        "uint256 sequenceId,"
        "address offeredTokenAddress,"
        "uint256 offeredTokenId,"
        "uint256 offeredQuantity,"
        "uint8 offeredTokenType,"
        "address desiredTokenAddress,"
        "uint256 desiredTokenId,"
        "uint256 desiredAmount,"
        "address maker,"
        "bool isSellOrder,"
        "uint256 salt,"
        "uint64 expiryTimestamp"
        ")"
    );
    uint256 private constant BASIS_POINTS_DIVISOR = 10000;

    address public feeRecipient;
    uint256 public platformFee;
    uint256 public batchOrderLimit;

    mapping(uint256 sequenceId => TradeOrder) public ordersById;
    mapping(bytes32 messageHash => bool executed) public executedOrderHashes;
    mapping(address token => bool allowed) public allowedTokens;

    struct ExchangeAsset {
        address tokenAddress;   // Address of token to be received
        uint256 tokenId;        // NFT ID (0 for ERC20)
        uint256 amount;         // Price or quantity to be received
    }

    struct TradeAsset {
        address tokenAddress;   // Address of the token
        uint256 tokenId;        // NFT ID (0 for fungible tokens)
        uint256 quantity;       // Number of tokens (1 for NFTs)
        uint8 tokenType;        // 0 = ERC20, 1 = ERC721, 2 = ERC1155
    }

    struct TradeOrder {
        uint256 sequenceId;            // Order sequence ID (nonce)
        address maker;                 // User who created the order
        TradeAsset offeredAsset;       // Asset being offered
        ExchangeAsset desiredAsset;    // What the user wants in return
        bool isSellOrder;              // True if it's a sell order
        uint256 salt;                  // Random number for uniqueness
        uint64 expiryTimestamp;        // Expiration time of the order
        bytes signature;               // EIP-712 or similar signature
    }
    
    event BatchOrderLimit(
        uint256 oldLimit, 
        uint256 newLimit
    );

    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );

    event PlatformFeeUpdated(
        uint256 oldPlatformFee,
        uint256 newPlatformFee
    );

    event TokenAuthorized(
        address indexed token,
        bool indexed authorized
    );

    event Exchange(
        address seller,
        address buyer,
        address nft,
        uint256 id,
        uint256 supply,
        address token,
        uint256 amount,
        uint256 platformFee,
        uint256 royaltyFee
    );

    event OrderCreated(
        address indexed maker, 
        uint256 indexed sequenceId
    );

    event OrderCancelled(
        address indexed user, 
        uint256 indexed orderId
    );


    constructor(
        address initRecipient,
        uint256 initPlatformFee,
        address initOwner
    ) Ownable(initOwner) EIP712("MarketPlace", "1.0") {
        _setFeeRecipient(initRecipient);
        _setPlatformFee(initPlatformFee);
    }

    function setFeeRecipient(address newRecipient) public onlyOwner {
        _setFeeRecipient(newRecipient);
    }

    function setPlatformFee(uint256 newFee) public onlyOwner {
        _setPlatformFee(newFee);
    }

    function setBatchOrderLimit(uint256 newBatchOrderLimit) public onlyOwner {
        require(newBatchOrderLimit != 0, "Zero limit");
        uint256 oldBatchOrderLimit = batchOrderLimit;
        batchOrderLimit = newBatchOrderLimit;
        emit BatchOrderLimit({
            oldLimit: oldBatchOrderLimit,
            newLimit : newBatchOrderLimit
        });
    }

    function authorizeToken(address[] memory token) public onlyOwner {
        require(token.length <= 20, "Exceed limit");
        for(uint i=0; i< token.length; i++) {
            allowedTokens[token[i]] = true;
            emit TokenAuthorized({
                token : token[i],
                authorized : true
            });
        }
    }

    function unauthorizeToken(address[] memory token) public onlyOwner {
        require(token.length <= 20, "Exceed limit");
        for(uint i=0; i< token.length; i++) {
            allowedTokens[token[i]] = false;
            emit TokenAuthorized({
                token : token[i],
                authorized : false
            });
        }
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function batchExecuteOrders	(
        TradeOrder[] memory sellOrders,
        TradeOrder[] memory buyOrders
    ) public {
        require(
            sellOrders.length <= batchOrderLimit &&
            sellOrders.length == buyOrders.length,
            "Invalid length"
        );
        for (uint256 i = 0; i < sellOrders.length; i++) {
            executeOrders(
                sellOrders[i],
                buyOrders[i]
            );
        }
    }

    function executeOrders(
        TradeOrder memory sellOrder,
        TradeOrder memory buyOrder
    ) public whenNotPaused nonReentrant {
        // Validate order types, assets, tokens, and users
        _validateOrdersType(sellOrder, buyOrder);
        // Validate maker (seller) order
        TradeOrder memory storedOrder = ordersById[sellOrder.sequenceId];
        // For one-time orders: validate signature and mark hash as used
        bool isValidMaker = (storedOrder.expiryTimestamp == 0)
            ? _validateOrder(sellOrder)
            : storedOrder.expiryTimestamp > block.timestamp;

        require(
            isValidMaker,
            "Invalid maker signature"
        );

        // Validate taker (buyer) signature
        require(
            _validateOrder(buyOrder),
            "Invalid taker signature"
        );

        if (sellOrder.offeredAsset.tokenType == uint8(AssetType.ERC1155)) {
            _storeFixedSellOrder(sellOrder, buyOrder.desiredAsset.amount);
        }
        
        // Transfer tokens and handle royalty
        _exchange(
            sellOrder,
            buyOrder
        );
    }

    function cancelOrder(TradeOrder memory order) public {
        require(order.maker == _msgSender(), "Invalid order caller");

        if (order.offeredAsset.tokenType != uint256(AssetType.ERC1155)) {
            require(
                _validateOrder(order),
                "Invalid zero sign message"
            );
        } else {
            uint256 sequenceId = order.sequenceId; 
            TradeOrder storage storedOrder = ordersById[sequenceId];
            if ((storedOrder.expiryTimestamp == 0)) {
                require(
                    _validateOrder(order),
                    "Invalid zero sign message"
                );
                order.offeredAsset.quantity = 0;
                ordersById[sequenceId] = order;
            } else {
                require(
                    storedOrder.offeredAsset.quantity > 0,
                    "Cancelled order"
                );
                storedOrder.offeredAsset.quantity = 0;
            }
        }

        emit OrderCancelled(
            order.maker, 
            order.sequenceId
        );
    }

    function _exchange(
        TradeOrder memory sellOrder,
        TradeOrder memory buyOrder
    ) private {
        uint256 unitPrice = sellOrder.desiredAsset.amount;
        uint256 totalPrice = unitPrice * (
            sellOrder.offeredAsset.tokenType == uint8(AssetType.ERC1155)
                ? buyOrder.desiredAsset.amount
                : 1
        );

        address paymentToken = sellOrder.desiredAsset.tokenAddress;
        address payer = buyOrder.maker;
        address payee = sellOrder.maker;

        (
            uint256 platformFeeAmount,
            uint256 sellerProceeds
        ) = computeFeeBreakdown(totalPrice, platformFee);

        address royaltyRecipient;
        uint256 royaltyFeeAmount = 0;
        
        bool isRoyaltySupported = false;
        try IERC165(sellOrder.offeredAsset.tokenAddress).supportsInterface(type(IERC2981).interfaceId) returns (bool result) {
            isRoyaltySupported = result;
        } catch {
            isRoyaltySupported = false;
        }

        if (isRoyaltySupported) {
            (royaltyRecipient, royaltyFeeAmount) = IERC2981(sellOrder.offeredAsset.tokenAddress).royaltyInfo(
                sellOrder.offeredAsset.tokenId, 
                totalPrice
            );

            // Pay royalty
            if (royaltyFeeAmount > 0 && royaltyRecipient != address(0)) {
                require(sellerProceeds >= royaltyFeeAmount, "Royalty fee exceeds seller proceeds");
                sellerProceeds -= royaltyFeeAmount;

                _sendERC20(IERC20(paymentToken), payer, royaltyRecipient, royaltyFeeAmount);
            }
        }

        // Pay platform
        if (platformFeeAmount > 0) {
            _sendERC20(
                IERC20(paymentToken),
                payer,
                feeRecipient,
                platformFeeAmount
            );
        }

        // Pay seller
        _sendERC20(IERC20(paymentToken), payer, payee, sellerProceeds);
        
        // settle NFT Asset
        _transferNFTAsset(
            sellOrder, 
            buyOrder, 
            payer, 
            payee
        );

        emit Exchange({
            seller : sellOrder.maker,
            buyer : buyOrder.maker,
            nft : sellOrder.offeredAsset.tokenAddress,
            id : sellOrder.offeredAsset.tokenId,
            supply: buyOrder.desiredAsset.amount,
            token : paymentToken,
            amount : sellerProceeds,
            platformFee : platformFeeAmount,
            royaltyFee : royaltyFeeAmount
        });
    }

    function _transferNFTAsset	(
        TradeOrder memory sellOrder, 
        TradeOrder memory buyOrder, 
        address payer, 
        address payee
    ) private {
        AssetType tokenType = AssetType(sellOrder.offeredAsset.tokenType);
        address nftAddress = sellOrder.offeredAsset.tokenAddress;
        uint256 tokenId = sellOrder.offeredAsset.tokenId;

        if (tokenType == AssetType.ERC721) {
            _sendERC721(IERC721(nftAddress), payee, payer, tokenId);
        } else if (tokenType == AssetType.ERC1155) {
            uint256 quantity = buyOrder.desiredAsset.amount;

            TradeOrder storage storedOrder = ordersById[sellOrder.sequenceId];
            uint256 orderQty = storedOrder.expiryTimestamp > 0
                ? storedOrder.offeredAsset.quantity
                : sellOrder.offeredAsset.quantity;

            require(
                quantity <= orderQty,
                "Exceeds available quantity"
            );

            // Update remaining quantity if from stored order
            if (storedOrder.expiryTimestamp > 0) {
                storedOrder.offeredAsset.quantity -= quantity;
            }

            _sendERC1155(
                IERC1155(nftAddress),
                payee,
                payer,
                tokenId,
                quantity
            );
        }
    }

    function _setFeeRecipient(address newRecipient) private {
        _checkNonZeroAddress(newRecipient);
        address oldRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated({
            oldRecipient : oldRecipient, 
            newRecipient : newRecipient
        });
    }

    function _setPlatformFee(uint256 newPlatformFee) private {
        require(
            (newPlatformFee > 0) && (newPlatformFee < 5000),
            "Invalid fee"
        );
        uint256 oldPlatformFee = platformFee;
        platformFee = newPlatformFee;
        emit PlatformFeeUpdated({
            oldPlatformFee: oldPlatformFee, 
            newPlatformFee: newPlatformFee
        });
    }

    function _sendERC20(
        IERC20 token,
        address sender,
        address receiver,
        uint256 amount
    ) private {
        token.safeTransferFrom(sender, receiver, amount);
    }

    function _sendERC721(
        IERC721 token,
        address sender,
        address receiver,
        uint256 tokenId
    ) private {
        token.safeTransferFrom(sender, receiver, tokenId, "0x");
    }

    function _sendERC1155(
        IERC1155 token,
        address sender,
        address receiver,
        uint256 tokenId,
        uint256 amount
    ) private {
        token.safeTransferFrom(sender, receiver, tokenId, amount, "0x");
    }

    function _storeFixedSellOrder(TradeOrder memory order, uint256 price) private {
        if (
            (ordersById[order.sequenceId].expiryTimestamp == 0) &&
            (price < order.offeredAsset.quantity)
        ) {
            ordersById[order.sequenceId] = order;
            emit OrderCreated(
                order.maker, 
                order.sequenceId
            );
        }
    }

    function _validateOrder(TradeOrder memory order) private returns (bool) {
        bytes32 messageHash = createMessageHash(order);
        bytes32 digestHash = _hashTypedDataV4(messageHash);
        require(
            !executedOrderHashes[digestHash],
            "Signed message already exists"
        );
        bool isValidSign = ECDSA.recover(digestHash, order.signature) == order.maker;
        if (isValidSign)
            executedOrderHashes[digestHash] = true;

        return isValidSign;
    }

    function _validateOrdersType(
        TradeOrder memory sellOrder,
        TradeOrder memory buyOrder
    ) private view {
        require(sellOrder.sequenceId != buyOrder.sequenceId, "Invalid operation");
        require(
            sellOrder.offeredAsset.tokenType == uint8(AssetType.ERC721) ||
            sellOrder.offeredAsset.tokenType == uint8(AssetType.ERC1155),
            "Seller asset type is invalid"
        );
        require(
            buyOrder.offeredAsset.tokenType == uint8(AssetType.ERC20),
            "Buyer asset type is invalid"
        );  
        // Validate token whitelisting and matching
        require(
            allowedTokens[buyOrder.offeredAsset.tokenAddress] &&
            allowedTokens[sellOrder.offeredAsset.tokenAddress],
            "Unauthorized token"
        );
        require(
            sellOrder.offeredAsset.tokenAddress == buyOrder.desiredAsset.tokenAddress &&
            buyOrder.offeredAsset.tokenAddress == sellOrder.desiredAsset.tokenAddress,
            "Asset and token mismatch"
        );
        // Ensure maker addresses differ
        require(buyOrder.maker != sellOrder.maker, "Invalid operation");
        // Order type and expiry validation
        require(sellOrder.isSellOrder && !buyOrder.isSellOrder, "Invalid order types");
        require(sellOrder.expiryTimestamp > block.timestamp, "Seller order has expired");
        require(buyOrder.expiryTimestamp > block.timestamp, "Buyer order has expired");
    }

    function createMessageHash(TradeOrder memory order)
        public
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    EXCHANGE_TYPEHASH,
                    order.sequenceId,
                    order.offeredAsset.tokenAddress,
                    order.offeredAsset.tokenId,
                    order.offeredAsset.quantity,
                    order.offeredAsset.tokenType,
                    order.desiredAsset.tokenAddress,
                    order.desiredAsset.tokenId,
                    order.desiredAsset.amount,
                    order.maker,
                    order.isSellOrder,
                    order.salt,
                    order.expiryTimestamp
                )
            );
    }

    function _checkNonZeroAddress(address account) private pure {
        require(account != address(0), "Zero address is not allowed");
    }

    function computeFeeBreakdown(
        uint256 amount,
        uint256 platformFees
    )
        private
        pure
        returns (
            uint256 platformFeeAmount,
            uint256 sellerProceeds
        )
    {
        platformFeeAmount = (amount * platformFees) / BASIS_POINTS_DIVISOR;
        sellerProceeds = amount - platformFeeAmount;
    }
}