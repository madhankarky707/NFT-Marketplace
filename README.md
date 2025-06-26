# 🛒 NFT & Token Marketplace Smart Contract

This project implements a Solidity-based on-chain **Marketplace** that supports trading of `ERC721` and `ERC1155` NFTs in exchange for `ERC20` tokens. It includes royalty and platform fee handling, batch order execution, and EIP-712-compatible off-chain order signing.

## 📦 Features

- Supports ERC20, ERC721, and ERC1155 tokens
- Buy/Sell orders with signature verification
- Batch order execution (matching sell and buy orders)
- Platform fee and royalty fee distribution
- Whitelisted ERC20 token handling
- ERC2981 royalty standard support
- Cancel individual orders (nonces)
- Full test suite using Truffle + Web3.js

## 🧾 Smart Contract

The main contract is `MarketPlace.sol`, with the following capabilities:

- `batchExecuteOrders()` – Execute multiple matching orders atomically.
- `executeOrders()` – Executes a matched buy/sell pair.
- `cancelOrder()` – Cancels an existing order by nonce.
- `authorizeToken()` / `unauthorizeToken()` – Manage accepted ERC20 tokens.
- Royalty payout is handled via ERC2981 if supported by the NFT.

## 🧪 Testing

### Mock Contracts

Mock contracts included in `test/mocks/`:
- `MockERC20.sol`
- `MockERC721.sol`
- `MockERC1155.sol`

### Run Tests

```bash
npx hardhat test
```

## 🛠 Requirements

- Node.js >= 18.x
- Hardhat ^2.25.0
- Truffle + Web3.js
- OpenZeppelin Contracts ^5.0

## 📁 Project Structure

```
contracts/
  - MarketPlace.sol
  - mocks/
    - MockERC20.sol
    - MockERC721.sol
    - MockERC1155.sol

test/
  - marketplace.test.js

ignition/
  - modules/
    - MarketPlaceModule.js
```

## 📜 License

MIT License. Built using OpenZeppelin contracts.