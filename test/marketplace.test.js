// test/test_marketplace.js
const Marketplace = artifacts.require("MarketPlace");
const ERC20Mock = artifacts.require("ERC20Mock");
const ERC721Mock = artifacts.require("ERC721Mock");
const ERC1155Mock = artifacts.require("ERC1155Mock");

const { expectRevert, expectEvent } = require("@openzeppelin/test-helpers");
const { web3 } = require("hardhat");
const { ethers } = require("ethers");
const { toWei } = web3.utils;

const keccak256 = ethers.keccak256;
const solidityPack = ethers.solidityPacked;

contract("Marketplace", (accounts) => {
  const [owner, seller, buyer, feeRecipient] = accounts;

  let marketplace, erc20, erc721;

  beforeEach(async () => {
    erc20 = await ERC20Mock.new("MockToken", "MTK", buyer, toWei("1000"), { from: owner });
    erc721 = await ERC721Mock.new("Mock721", "M721", { from: owner });
    erc1155 = await ERC1155Mock.new({ from: owner });

    // Mint NFT to seller
    await erc721.mint(seller, 1, { from: owner });

    // Deploy marketplace with 5% fee
    marketplace = await Marketplace.new(feeRecipient, 500, owner, { from: owner });

    // Authorize ERC20
    await marketplace.authorizeToken([erc20.address], { from: owner });

    // Approve
    await erc721.approve(marketplace.address, 1, { from: seller });
    await erc20.approve(marketplace.address, toWei("1000"), { from: buyer });
  });

  function createMessageHash(order) {
    return keccak256(solidityPack(
      ["uint256", "address", "uint256", "uint256", "uint8",
        "address", "uint256", "uint256", "address", "bool", "uint64"],
      [
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
        order.expiryTimestamp
      ]
    ));
  }

  async function signOrder(order, account) {
    const hash = createMessageHash(order);
    const signature = await web3.eth.accounts.sign(hash, account);
    return signature;
  }

  it("executes a simple ERC721 <-> ERC20 trade with valid signatures", async () => {
    const unitPrice = toWei("100");
    const expiry = Math.floor(Date.now() / 1000) + 3600;

    const sellOrder = {
      sequenceId: 1,
      maker: seller,
      offeredAsset: {
        tokenAddress: erc721.address,
        tokenId: 1,
        quantity: 1,
        tokenType: 1 // ERC721
      },
      desiredAsset: {
        tokenAddress: erc20.address,
        tokenId: 0,
        amount: unitPrice
      },
      isSellOrder: true,
      salt: 123,
      expiryTimestamp: expiry,
      signature: ""
    };

    const buyOrder = {
      sequenceId: 2,
      maker: buyer,
      offeredAsset: {
        tokenAddress: erc20.address,
        tokenId: 0,
        quantity: unitPrice,
        tokenType: 0 // ERC20
      },
      desiredAsset: {
        tokenAddress: erc721.address,
        tokenId: 1,
        amount: 1
      },
      isSellOrder: false,
      salt: 456,
      expiryTimestamp: expiry,
      signature: ""
    };

    sellOrder.signature = (await signOrder(sellOrder, "SELLER")).signature;
    buyOrder.signature = (await signOrder(buyOrder, "BUYER")).signature;

    const tx = await marketplace.executeOrders(sellOrder, buyOrder, { from: buyer });

    expectEvent(tx, "Exchange", {
      seller: seller,
      buyer: buyer,
      nft: erc721.address,
      id: web3.utils.toBN("1"),
      token: erc20.address
    });

    const newOwner = await erc721.ownerOf("1");
    assert.equal(newOwner, buyer, "NFT was not transferred");

    const sellerBal = await erc20.balanceOf(seller);
    assert.equal(sellerBal.toString(), toWei("95"), "Seller did not receive net proceeds");
  });

  it("rejects when signature is invalid", async () => {
    const unitPrice = toWei("10");
    const expiry = Math.floor(Date.now() / 1000) + 3600;

    const bogusOrder = {
      sequenceId: 1,
      maker: seller,
      offeredAsset: {
        tokenAddress: erc721.address,
        tokenId: 1,
        quantity: 1,
        tokenType: 1
      },
      desiredAsset: {
        tokenAddress: erc20.address,
        tokenId: 0,
        amount: unitPrice
      },
      isSellOrder: true,
      salt: 0,
      expiryTimestamp: expiry,
      signature: "0xdeadbeef"
    };

    const buyOrder = {
      sequenceId: 2,
      maker: buyer,
      offeredAsset: {
        tokenAddress: erc20.address,
        tokenId: 0,
        quantity: unitPrice,
        tokenType: 0
      },
      desiredAsset: {
        tokenAddress: erc721.address,
        tokenId: 1,
        amount: 1
      },
      isSellOrder: false,
      salt: 0,
      expiryTimestamp: expiry,
      signature: ""
    };

    buyOrder.signature = (await signOrder(buyOrder, "BUYER")).signature;

    await expectRevert(
      marketplace.executeOrders(bogusOrder, buyOrder, { from: buyer }),
      "Invalid maker signature"
    );
  });

});
