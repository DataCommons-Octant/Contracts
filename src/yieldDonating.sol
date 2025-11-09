// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {BaseStrategy} from "../lib/octant-v2-core/src/core/BaseStrategy.sol";
import {YieldDonatingTokenizedStrategy} from "../lib/octant-v2-core/src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import {PaymentSplitter} from "../lib/octant-v2-core/src/core/PaymentSplitter.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Interface for a generic yield source (e.g., Aave, Compound)
 * @dev This interface defines the essential functions for supplying and withdrawing assets from a yield source.
 */
interface IYieldSource {
    /**
     * @notice Supplies assets to the yield source
     * @param asset The address of the asset to supply
     * @param amount The amount of the asset to supply
     * @param onBehalfOf The address on whose behalf the assets are supplied
     * @param referralCode A referral code for tracking purposes
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /**
     * @notice Withdraws assets from the yield source
     * @param asset The address of the asset to withdraw
     * @param amount The amount of the asset to withdraw
     * @param to The address to which the withdrawn assets will be sent
     * @return The actual amount withdrawn
     */
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

contract YieldDonating is BaseStrategy {
    using SafeERC20 for ERC20;

    IYieldSource yieldSource; // The yield source (e.g., Aave) where funds are deployed
    YieldDonatingTokenizedStrategy tokenizedStrategy; // The associated tokenized strategy contract
    address public immutable aUSDC = address(0x0); // Aave interest bearing USDC token address on Ethereum mainnet(to be replaced with actual address)
    address private immutable paymentSplitterAddress; // Address of the payment splitter contract for donations

    /** @notice Constructor for the YieldDonating strategy
     * @param _yieldSource The address of the yield source contract
     * @param _asset The address of the asset managed by the strategy
     * @param _name The name of the strategy
     * @param _management The address of the management
     * @param _keeper The address of the keeper
     * @param _emergencyAdmin The address of the emergency admin
     * @param _donationAddress The address where donation shares are sent
     * @param _enableBurning Boolean indicating if burning of donation shares is enabled
     * @param _tokenizedStrategyAddress The address of the associated tokenized strategy contract
     */
    constructor(
        address _yieldSource,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseStrategy(
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {
        yieldSource = IYieldSource(_yieldSource);
        tokenizedStrategy = YieldDonatingTokenizedStrategy(
            _tokenizedStrategyAddress
        );
        paymentSplitterAddress = _donationAddress;
    }

    // x-----------------------------------------------   Public Write Functions   ----------------------------------------------------x

    /**
     * @notice Deposits funds into the strategy
     * @dev the actual logic for depositing funds is handled by the octant v2 contracts tokenized
     *      strategy and base strategy
     * @param _amount The amount of funds to deposit
     */
    function depositFunds(uint256 _amount) public {
        tokenizedStrategy.deposit(_amount, msg.sender);
    }

    /**
     * @notice Withdraws funds from the strategy
     * @dev the actual logic for withdrawing funds is handled by the octant v2 contracts tokenized
     *      strategy and base strategy
     * @param _amount The amount of funds to withdraw
     */
    function withdrawFunds(uint256 _amount) public {
        tokenizedStrategy.withdraw(_amount, msg.sender, msg.sender);
    }

    /**
     * @notice Harvests yield and donates it to the donation address(payment splitter contract)
     * @dev Calls the report function of the tokenized strategy to harvest yield, which in turn calls
     *      the harvestAndReport function of the base strategy contract
     */
    function transferYieldToDonationAddress() public {
        tokenizedStrategy.report();
    }

    /**
     * @notice Claims payment from the payment splitter contract
     * @dev Allows a payee to claim their share of the payments from the payment splitter
     */
    function claimPayment() public {
        IERC20 token = IERC20(asset);
        PaymentSplitter(paymentSplitterAddress).release(token, msg.sender);
    }

    // x-----------------------------------------------   Internal Override Functions   -----------------------------------------------x

    /**
     * @dev Implementation of the _deployFunds function of the BaseStrategy contract, which is
     *      responsible for deploying funds to the yield source.
     * @param _amount The amount of funds to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
        yieldSource.supply(address(asset), _amount, address(this), 0);
    }

    /**
     * @dev Implementation of the _freeFunds function of the BaseStrategy contract, which is
     *      responsible for withdrawing funds from the yield source.
     * @param _amount The amount of funds to withdraw
     */
    function _freeFunds(uint256 _amount) internal override {
        yieldSource.withdraw(address(asset), _amount, address(this));
    }

    /**
     * @dev Implementation of the _harvestAndReport function of the BaseStrategy contract, which is
     *      responsible for harvesting yield and reporting total assets.
     * @return _totalAssets The total assets managed by the strategy
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        uint256 assetsClaimable = ERC20(aUSDC).balanceOf(address(this));
        uint256 assetsIdle = asset.balanceOf(address(this));

        _totalAssets = assetsClaimable + assetsIdle;
    }
}
