const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("MarketPlaceModule", (m) => {
  // Parameters
  const feeRecipient = m.getParameter("feeRecipient", m.getAccount(0));
  const platformFee = m.getParameter("platformFee", 250); // 2.5% (250 basis points)
  const owner = m.getParameter("owner", m.getAccount(0));

  // Deploy the MarketPlace contract
  const marketplace = m.contract("MarketPlace", [
    feeRecipient,
    platformFee,
    owner,
  ]);

  return { marketplace };
});
