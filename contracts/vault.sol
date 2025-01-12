// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "hardhat/console.sol"; // For debugging
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

// Chainlink Oracle Interface
interface EACAggregatorProxy {
    function latestAnswer() external view returns (int256);
}

// Uniswap V3 Router Interface
interface IUniswapRouter is ISwapRouter {
    function refundETH() external payable;
}

// WETH Interface (supports deposit)
interface DepositableERC20 is IERC20 {
    function deposit() external payable;
}

/**
 * @title Vault
 * @dev A contract for managing a portfolio of DAI and WETH, with rebalancing and dividend distribution functionality.
 */
contract Vault {
    uint256 public version = 1;

    address public daiAddress;
    address public wethAddress;
    address public uniswapV3QuoterAddress;
    address public uniswapV3RouterAddress;
    address public chainlinkETHUSDPriceFeedAddress;

    uint256 public usdTargetPercentage = 40; // Target DAI percentage in the portfolio
    uint256 public usdDividendPercentage = 25; // Dividend percentage
    uint256 public dividendFrequency = 3 minutes; // Dividend distribution frequency
    uint256 public nextDividendTime; // Next dividend distribution time
    address public owner;

    using SafeERC20 for IERC20;
    using SafeERC20 for DepositableERC20;

    IERC20 public dai;
    DepositableERC20 public weth;
    IQuoter public uniswapV3Quoter;
    IUniswapRouter public uniswapV3Router;

    EACAggregatorProxy public chainlinkETHUSDPriceFeed;

    event MyVaultLog(string msg, uint256 ref);
    event WETHBought(uint256 daiAmount, uint256 wethReceived);
    event WETHSold(uint256 wethAmount, uint256 daiReceived);
    event Rebalanced(uint256 daiBalance, uint256 wethBalance);
    event DividendsDistributed(uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EthPriceUpdated(uint256 newPrice);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    /**
     * @dev Constructor to initialize the contract.
     * @param _daiAddress Address of the DAI token.
     * @param _wethAddress Address of the WETH token.
     * @param _uniswapV3QuoterAddress Address of the Uniswap V3 Quoter.
     * @param _uniswapV3RouterAddress Address of the Uniswap V3 Router.
     * @param _chainlinkETHUSDPriceFeedAddress Address of the Chainlink ETH/USD price feed.
     */
    constructor(
        address _daiAddress,
        address _wethAddress,
        address _uniswapV3QuoterAddress,
        address _uniswapV3RouterAddress,
        address _chainlinkETHUSDPriceFeedAddress
    ) {
        daiAddress = _daiAddress;
        wethAddress = _wethAddress;
        uniswapV3QuoterAddress = _uniswapV3QuoterAddress;
        uniswapV3RouterAddress = _uniswapV3RouterAddress;
        chainlinkETHUSDPriceFeedAddress = _chainlinkETHUSDPriceFeedAddress;

        dai = IERC20(daiAddress);
        weth = DepositableERC20(wethAddress);
        uniswapV3Quoter = IQuoter(uniswapV3QuoterAddress);
        uniswapV3Router = IUniswapRouter(uniswapV3RouterAddress);
        chainlinkETHUSDPriceFeed = EACAggregatorProxy(chainlinkETHUSDPriceFeedAddress);
        nextDividendTime = block.timestamp + dividendFrequency;

        owner = msg.sender;
    }

    /**
     * @dev Get the current DAI balance of the contract.
     * @return The DAI balance.
     */
    function getDaiBalance() public view returns (uint256) {
        return dai.balanceOf(address(this));
    }

    /**
     * @dev Get the current WETH balance of the contract.
     * @return The WETH balance.
     */
    function getWethBalance() public view returns (uint256) {
        return weth.balanceOf(address(this));
    }

    /**
     * @dev Get the current ETH balance of the contract.
     * @return The ETH balance.
     */
    function getEthBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Get the total portfolio value in USD.
     * @return The total portfolio value in USD.
     */
    function getTotalBalance() public view returns (uint256) {
        uint256 daiBalance = getDaiBalance();
        uint256 wethBalance = getWethBalance();
        uint256 ethPrice = getEthPrice();
        uint256 wethUSD = (wethBalance * ethPrice) / 1e18; // Convert WETH to USD
        return daiBalance + wethUSD;
    }

    /**
     * @dev Get the current ETH price in USD from Chainlink.
     * @return The ETH price in USD.
     */
    function getEthPrice() public view returns (uint256) {
        return uint256(chainlinkETHUSDPriceFeed.latestAnswer());
    }

    /**
     * @dev Fetches the latest ETH price from Uniswap V3 and updates the `ethPrice` state variable.
     * @return The updated ETH price.
     */
    function updateEthPriceUniswap() public returns (uint256) {
        // Define the amount of DAI to quote (1 DAI)
        uint256 amountIn = 1e18; // 1 DAI (18 decimals)

        // Fetch the price from Uniswap V3
        uint256 ethPriceRaw = uniswapV3Quoter.quoteExactInputSingle(
            daiAddress,
            wethAddress,
            3000, // 0.3% fee tier
            amountIn,
            0 // sqrtPriceLimitX96 (0 means no limit)
        );

        // Ensure the price is valid (greater than 0)
        require(ethPriceRaw > 0, "Invalid price from Uniswap");

        

        // Emit an event to log the updated price
        emit EthPriceUpdated(ethPriceRaw);

        return ethPriceRaw;
    }

    /**
     * @dev Buy WETH using DAI.
     * @param daiAmount The amount of DAI to spend.
     */
    function buyWETH(uint256 daiAmount) internal onlyOwner {
        require(daiAmount > 0, "DAI amount must be greater than 0");
        require(dai.balanceOf(address(this)) >= daiAmount, "Insufficient DAI balance");

        uint256 deadline = block.timestamp + 300; // 5 minutes deadline
        uint24 fee = 3000; // Pool fee tier (0.3%)
        address recipient = address(this);
        uint256 amountOutMinimum = 0; // Adjust based on slippage tolerance
        uint160 sqrtPriceLimitX96 = 0; // Price limit (0 means no limit)

        emit MyVaultLog("Buying WETH", daiAmount);

        // Approve the Uniswap router to spend DAI
        require(dai.approve(uniswapV3RouterAddress, daiAmount), "DAI approval failed");

        // Define the swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
            daiAddress,
            wethAddress,
            fee,
            recipient,
            deadline,
            daiAmount,
            amountOutMinimum,
            sqrtPriceLimitX96
        );

        // Execute the swap
        uint256 wethBalanceBefore = weth.balanceOf(address(this));
        uniswapV3Router.exactInputSingle(params);
        uint256 wethBalanceAfter = weth.balanceOf(address(this));

        emit WETHBought(daiAmount, wethBalanceAfter - wethBalanceBefore);
    }

    /**
     * @dev Sell WETH for DAI.
     * @param wethAmount The amount of WETH to sell.
     */
    function sellWETH(uint256 wethAmount) internal onlyOwner {
        require(wethAmount > 0, "WETH amount must be greater than 0");
        require(weth.balanceOf(address(this)) >= wethAmount, "Insufficient WETH balance");

        uint256 deadline = block.timestamp + 300; // 5 minutes deadline
        uint24 fee = 3000; // Pool fee tier (0.3%)
        address recipient = address(this);
        uint256 amountOutMinimum = 0; // Adjust based on slippage tolerance
        uint160 sqrtPriceLimitX96 = 0; // Price limit (0 means no limit)

        emit MyVaultLog("Selling WETH", wethAmount);

        // Approve the Uniswap router to spend WETH
        require(weth.approve(uniswapV3RouterAddress, wethAmount), "WETH approval failed");

        // Define the swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
            wethAddress,
            daiAddress,
            fee,
            recipient,
            deadline,
            wethAmount,
            amountOutMinimum,
            sqrtPriceLimitX96
        );

        // Execute the swap
        uint256 daiBalanceBefore = dai.balanceOf(address(this));
        uniswapV3Router.exactInputSingle(params);
        uint256 daiBalanceAfter = dai.balanceOf(address(this));

        emit WETHSold(wethAmount, daiBalanceAfter - daiBalanceBefore);
    }

    /**
     * @dev Rebalance the portfolio to maintain the target DAI percentage.
     */
    function rebalance() public onlyOwner {
        uint256 daiBalance = getDaiBalance(); // DAI balance (1 DAI = 1 USD)
        uint256 wethBalance = getWethBalance(); // WETH balance
        uint256 ethPrice = getEthPrice(); // Price of ETH in USD (with 18 decimals)
        uint256 totalBalance = daiBalance + (wethBalance * ethPrice) / 1e18; // Total portfolio value in USD

        // Calculate current DAI balance percentage
        uint256 usdBalancePercentage = (daiBalance * 100) / totalBalance;

        emit MyVaultLog("Rebalancing", usdBalancePercentage);

        // Rebalance logic
        if (usdBalancePercentage < usdTargetPercentage) {
            // If DAI balance is below target, sell WETH to buy DAI
            uint256 deficitDAI = (totalBalance * usdTargetPercentage / 100) - daiBalance;
            uint256 wethToSell = (deficitDAI * 1e18) / ethPrice; // Convert deficit DAI to WETH
            if (wethToSell > wethBalance) {
                wethToSell = wethBalance; // Sell all available WETH if deficit is larger
            }
            require(wethToSell > 0, "Nothing to sell");
            sellWETH(wethToSell); // Sell WETH for DAI
        } else if (usdBalancePercentage > usdTargetPercentage) {
            // If DAI balance is above target, sell excess DAI for WETH
            uint256 excessDAI = daiBalance - (totalBalance * usdTargetPercentage / 100);
            require(excessDAI > 0, "Nothing to buy");
            buyWETH(excessDAI); // Buy WETH with DAI
        }

        emit Rebalanced(getDaiBalance(), getWethBalance());
    }

    /**
 * @dev Distribute dividends to the owner.
 * Requirements:
 * - The current timestamp must be greater than or equal to the next dividend distribution time.
 * - The contract must have a sufficient DAI balance to distribute dividends.
 * - The dividend amount must be greater than 0.
 * - The owner address must be valid (not the zero address).
 */
    function distributeDividends() public onlyOwner {
        require(block.timestamp >= nextDividendTime, "Dividend distribution not yet due");
        require(dividendFrequency > 0, "Dividend frequency not set");

        uint256 daiBalance = getDaiBalance();
        uint256 dividendAmount = (daiBalance * usdDividendPercentage) / 100;

        require(dividendAmount > 0, "No dividends to distribute");
        require(owner != address(0), "Owner address not set");

        // Transfer dividends to the owner
        require(dai.transfer(owner, dividendAmount), "Dividend transfer failed");

        // Update the next dividend distribution time
        nextDividendTime = block.timestamp + dividendFrequency;

        // Emit an event to log the dividend distribution
        emit DividendsDistributed(dividendAmount);
    }

    /**
     * @dev Wrap ETH into WETH.
     */
    function wrapETH() public onlyOwner {
        uint256 ethBalance = address(this).balance;
        require(ethBalance > 0, "No ETH available to wrap");

        emit MyVaultLog("Wrapping ETH", ethBalance);
        weth.deposit{value: ethBalance}();
    }

    /**
     * @dev Transfer ownership of the contract.
     * @param newOwner The address of the new owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner cannot be the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @dev Close the account and transfer all funds to the owner.
     */
    function closeAccount() public onlyOwner {
        uint256 daiBalance = getDaiBalance();
        if (daiBalance > 0) {
            dai.safeTransfer(owner, daiBalance);
        }

        uint256 wethBalance = getWethBalance();
        if (wethBalance > 0) {
            weth.safeTransfer(owner, wethBalance);
        }
    }

    /**
     * @dev Fallback function to accept ETH.
     */
    receive() external payable {}
}