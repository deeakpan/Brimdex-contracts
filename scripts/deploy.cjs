const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  if (!deployer) {
    throw new Error("No deployer found. Set DEPLOYER_PRIVATE_KEY.");
  }

  const usdcAddress = process.env.USDC_ADDRESS;
  if (!usdcAddress) {
    throw new Error("USDC_ADDRESS is required in .env");
  }

  const feedsAddress = process.env.PRICE_FEED_REGISTRY_ADDRESS || process.env.FEEDS_ADDRESS;
  if (!feedsAddress) {
    throw new Error("Set PRICE_FEED_REGISTRY_ADDRESS (or FEEDS_ADDRESS) in .env");
  }

  const treasuryAddress = process.env.TREASURY_ADDRESS || deployer.address;
  const dataStreamsAddress =
    process.env.DATA_STREAMS_ADDRESS || "0xB1Ae08D3d1542eF9971A63Aede2dB8d0239c78d4";
  const purchaseSchemaId =
    process.env.PURCHASE_SCHEMA_ID ||
    "0xd1e3226269cf1053c82a92ccf174d8a2cb06df1a7b9fd50d6d91156637aecefb";

  console.log("Deployer:", deployer.address);
  console.log("USDC:", usdcAddress);
  console.log("Feeds:", feedsAddress);
  console.log("Treasury:", treasuryAddress);

  const Factory = await hre.ethers.getContractFactory("BrimdexFactory");
  const factory = await Factory.deploy(
    usdcAddress,
    feedsAddress,
    deployer.address,
    treasuryAddress
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("BrimdexFactory:", factoryAddress);

  const OrderBookLinkedList = await hre.ethers.getContractFactory("OrderBookLinkedList");
  const orderBookLinkedList = await OrderBookLinkedList.deploy();
  await orderBookLinkedList.waitForDeployment();
  const orderBookLinkedListAddress = await orderBookLinkedList.getAddress();
  console.log("OrderBookLinkedList:", orderBookLinkedListAddress);

  const OrderBook = await hre.ethers.getContractFactory("BrimdexOrderBook", {
    libraries: {
      OrderBookLinkedList: orderBookLinkedListAddress,
    },
  });
  const orderBook = await OrderBook.deploy(usdcAddress, factoryAddress, deployer.address);
  await orderBook.waitForDeployment();
  const orderBookAddress = await orderBook.getAddress();
  console.log("BrimdexOrderBook:", orderBookAddress);

  const Router = await hre.ethers.getContractFactory("BrimdexRouter");
  const router = await Router.deploy(
    usdcAddress,
    factoryAddress,
    dataStreamsAddress,
    purchaseSchemaId
  );
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("BrimdexRouter:", routerAddress);

  const deploymentInfo = {
    network: hre.network.name,
    deployer: deployer.address,
    usdc: usdcAddress,
    feeds: feedsAddress,
    treasury: treasuryAddress,
    factory: factoryAddress,
    orderBook: orderBookAddress,
    router: routerAddress,
    libraries: {
      OrderBookLinkedList: orderBookLinkedListAddress,
    },
    timestamp: new Date().toISOString(),
  };

  console.log("\nDeployment summary:");
  console.log(JSON.stringify(deploymentInfo, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
