const Marketplace = artifacts.require("MarketPlace");
const ERC20Mock = artifacts.require("ERC20Mock");
const ERC721Mock = artifacts.require("ERC721Mock");
const ERC1155Mock = artifacts.require("ERC1155Mock");

const { expectEvent } = require("@openzeppelin/test-helpers");
const { ethers } = require("ethers");
const { toWei } = web3.utils;

contract("Marketplace", (accounts) => {
  const [owner, seller, buyer, feeRecipient] = accounts;

  let marketplace, erc20, erc721, erc1155;
  let provider, sellerWallet, buyerWallet;

  before(async () => {
    provider = new ethers.JsonRpcProvider("http://localhost:8545");

    sellerWallet = new ethers.Wallet(
      "PRIVATEKEY",
      provider
    );
    buyerWallet = new ethers.Wallet(
      "PRIVATEKEY",
      provider
    );
  });

  beforeEach(async () => {
    erc20 = await ERC20Mock.new("MockToken", "MTK", buyer, toWei("1000"), { from: owner });
    erc721 = await ERC721Mock.new("Mock721", "M721", { from: owner });
    erc1155 = await ERC1155Mock.new({ from: owner });

    await erc721.mint(seller, 1, { from: owner });

    marketplace = await Marketplace.new(feeRecipient, 500, owner, { from: owner });
    await marketplace.authorizeToken([erc20.address, erc721.address], { from: owner });

    await erc721.approve(marketplace.address, 1, { from: seller });
    await erc20.approve(marketplace.address, toWei("1000"), { from: buyer });
  });

  async function signOrderEIP712(order, signer, verifyingContract) {
    const chainId = (await provider.getNetwork()).chainId;

    const domain = {
      name: "MarketPlace",
      version: "1.0",
      chainId,
      verifyingContract,
    };

    const types = {
      Order: [
        { name: "sequenceId", type: "uint256" },
        { name: "offeredTokenAddress", type: "address" },
        { name: "offeredTokenId", type: "uint256" },
        { name: "offeredQuantity", type: "uint256" },
        { name: "offeredTokenType", type: "uint8" },
        { name: "desiredTokenAddress", type: "address" },
        { name: "desiredTokenId", type: "uint256" },
        { name: "desiredAmount", type: "uint256" },
        { name: "maker", type: "address" },
        { name: "isSellOrder", type: "bool" },
        { name: "salt", type: "uint256" },
        { name: "expiryTimestamp", type: "uint64" },
      ],
    };

    const value = {
      sequenceId: order.sequenceId,
      offeredTokenAddress: order.offeredAsset.tokenAddress,
      offeredTokenId: order.offeredAsset.tokenId,
      offeredQuantity: order.offeredAsset.quantity,
      offeredTokenType: order.offeredAsset.tokenType,
      desiredTokenAddress: order.desiredAsset.tokenAddress,
      desiredTokenId: order.desiredAsset.tokenId,
      desiredAmount: order.desiredAsset.amount,
      maker: order.maker,
      isSellOrder: order.isSellOrder,
      salt: order.salt,
      expiryTimestamp: order.expiryTimestamp,
    };

    return signer.signTypedData(domain, types, value);
  }

  it("executes ERC721 <-> ERC20 trade with EIP712 signatures", async () => {
    const unitPrice = toWei("100");
    const expiry = Math.floor(Date.now() / 1000) + 3600;

    const sellOrder = {
      sequenceId: 1,
      maker: seller,
      offeredAsset: {
        tokenAddress: erc721.address,
        tokenId: 1,
        quantity: 1,
        tokenType: 1,
      },
      desiredAsset: {
        tokenAddress: erc20.address,
        tokenId: 0,
        amount: unitPrice,
      },
      isSellOrder: true,
      salt: 123,
      expiryTimestamp: expiry,
    };

    const buyOrder = {
      sequenceId: 2,
      maker: buyer,
      offeredAsset: {
        tokenAddress: erc20.address,
        tokenId: 0,
        quantity: unitPrice,
        tokenType: 0,
      },
      desiredAsset: {
        tokenAddress: erc721.address,
        tokenId: 1,
        amount: 1,
      },
      isSellOrder: false,
      salt: 456,
      expiryTimestamp: expiry,
    };

    sellOrder.signature = await signOrderEIP712(sellOrder, sellerWallet, marketplace.address);
    buyOrder.signature = await signOrderEIP712(buyOrder, buyerWallet, marketplace.address);

    const tx = await marketplace.executeOrders(
      sellOrder,
      buyOrder,
      { from: buyer }
    );

    expectEvent(tx, "Exchange", {
      seller,
      buyer,
      nft: erc721.address,
      id: web3.utils.toBN("1"),
      token: erc20.address,
    });

    const newOwner = await erc721.ownerOf("1");
    assert.equal(newOwner, buyer);

    const sellerBalance = await erc20.balanceOf(seller);
    assert.equal(sellerBalance.toString(), toWei("95")); // 5% fee deducted
  });
});
