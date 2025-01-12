const hre = require('hardhat');
const { expect } = require('chai');

describe('myVault', () => {
  let myVault;
  let dai;
  let weth;
  let owner;
  let mockpricefeed;
  let otherAccount;

  beforeEach(async function () {
    // Get signers
    [owner, otherAccount] = await hre.ethers.getSigners();

    // Deploy mock DAI contract
    const DAIMock = await hre.ethers.getContractFactory('DAIMock');
    dai = await DAIMock.deploy();
    await dai.waitForDeployment();
    console.log('DAIMock deployed to:', await dai.getAddress());

    // Deploy mock WETH contract
    const WETHMock = await hre.ethers.getContractFactory('WETHMock');
    weth = await WETHMock.deploy();
    await weth.waitForDeployment();
    console.log('WETHMock deployed to:', await weth.getAddress());

    // Deploy mock price feed
    const mockPriceFeed = await hre.ethers.getContractFactory("MockChainlinkPriceFeed");
    mockpricefeed = await mockPriceFeed.deploy("3000");
    await mockpricefeed.waitForDeployment();
    console.log('FEED PRICE deployed to', await mockpricefeed.getAddress());

    const xUniswapV3QuoterAddress = '0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3';
    const xUniswapV3RouterAddress = '0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E';


    // Deploy myVault contract
    const MyVault = await hre.ethers.getContractFactory('Vault');
    myVault = await MyVault.deploy(
      await dai.getAddress(),
      await weth.getAddress(),
      xUniswapV3QuoterAddress, // Replace with actual Uniswap V3 Quoter address
      xUniswapV3RouterAddress, // Replace with actual Uniswap V3 Router address
      await mockpricefeed.getAddress() // Replace with actual Chainlink ETH/USD price feed address
    );
    await myVault.waitForDeployment();
    console.log('myVault deployed to:', await myVault.getAddress());
  });

  it('Should return the correct version', async () => {
    const version = await myVault.version();
    expect(version).to.equal(1);
  });

  it('Should return zero DAI balance initially', async () => {
    const daiBalance = await myVault.getDaiBalance();
    expect(daiBalance).to.equal(0);
  });

  it('Should wrap ETH into WETH', async () => {
    // Send ETH to the contract
    const ethAmount = ethers.parseEther('0.01');
    await owner.sendTransaction({
      to: await myVault.getAddress(),
      value: ethAmount,
    });

    // Wrap ETH into WETH
    await myVault.wrapETH();

    // Check WETH balance
    const wethBalance = await myVault.getWethBalance();
    expect(wethBalance).to.equal(ethAmount);
  });

  it('Should rebalance the portfolio', async () => {
    // Send ETH to the contract and wrap it into WETH
    const ethAmount = ethers.parseEther('0.01');
    await owner.sendTransaction({
      to: await myVault.getAddress(),
      value: ethAmount,
    });
    await myVault.wrapETH();

    // Update ETH price from Uniswap (mock this if needed)
    await myVault.updateEthPriceUniswap();

    // Rebalance the portfolio
    await myVault.rebalance();

    // Check DAI balance after rebalancing
    const daiBalance = await myVault.getDaiBalance();
    console.log('Rebalanced DAI Balance:', daiBalance.toString());
    expect(daiBalance).to.be.above(0);

    // Check WETH balance after rebalancing
    const wethBalance = await myVault.getWethBalance();
    console.log('Rebalanced WETH Balance:', wethBalance.toString());
    expect(wethBalance).to.be.below(ethAmount); // Some WETH should have been sold for DAI

    // Check total portfolio value
    const totalBalance = await myVault.getTotalBalance();
    console.log('Total Portfolio Value:', totalBalance.toString());
    expect(totalBalance).to.be.above(0);
  });

  it('Should revert if non-owner tries to rebalance', async () => {
    // Attempt to rebalance from a non-owner account
    await expect(myVault.connect(otherAccount).rebalance()).to.be.revertedWith(
      'Only owner can call this function'
    );
  });

  it('Should emit Rebalanced event', async () => {
    // Send ETH to the contract and wrap it into WETH
    const ethAmount = ethers.parseEther('0.01');
    await owner.sendTransaction({
      to: await myVault.getAddress(),
      value: ethAmount,
    });
    await myVault.wrapETH();

    // Update ETH price from Uniswap (mock this if needed)
    await myVault.updateEthPriceUniswap();

    // Rebalance the portfolio and check for the Rebalanced event
    await expect(myVault.rebalance())
      .to.emit(myVault, 'Rebalanced')
      .withArgs(await myVault.getDaiBalance(), await myVault.getWethBalance());
  });
});