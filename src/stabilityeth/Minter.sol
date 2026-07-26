// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { IAppRegistry } from "@stabilityeth/base/interfaces/IAppRegistry.sol";
import { IPBRTreasury } from "@stabilityeth/base/interfaces/IPBRTreasury.sol";
import { SETH } from "@stabilityeth/SETH.sol";

/**
 * @title Minter
 * @notice Optional immutable app router over SETH: attribute mint volume for PBR.
 * @dev Deposit: `SETH.deposit` (mints to this) → transfer SETH to user → `recordMint`.
 *      Withdraw: pull SETH from user → `SETH.withdraw` → forward ETH → `recordBurn`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract Minter {
    using SafeERC20 for IERC20;

    // --------------------------------------------
    //  Immutables
    // --------------------------------------------

    SETH public immutable seth;
    bytes32 public immutable appId;
    IAppRegistry public immutable registry;

    // --------------------------------------------
    //  State
    // --------------------------------------------

    /// @notice Cumulative SETH minted through this minter (mirrors `AppRegistry.totalMinted`)
    uint256 public totalMinted;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event Minted(address indexed user, uint256 ethIn, uint256 sethAmount);
    event Burned(address indexed user, uint256 sethAmount, uint256 ethOut);
    event YieldClaimed(address indexed beneficiary, uint64 indexed epochId, uint256 amount);

    error ZeroAddress();
    error ZeroAppId();
    error InvalidAmount();
    error NotBeneficiary();
    error TreasuryNotSet();
    error EthTransferFailed();

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyBeneficiary() {
        if (!registry.isBeneficiary(appId, msg.sender)) revert NotBeneficiary();
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    constructor(address seth_, bytes32 appId_, address registry_) {
        if (seth_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        if (appId_ == bytes32(0)) revert ZeroAppId();
        seth = SETH(payable(seth_));
        appId = appId_;
        registry = IAppRegistry(registry_);
    }

    // --------------------------------------------
    //  (Relay) Deposit / Withdraw
    // --------------------------------------------

    receive() external payable {
        // ETH from SETH.withdraw is handled by `withdraw`; other ETH is a deposit.
        if (msg.sender == address(seth)) return;
        deposit();
    }

    /**
     * @notice Deposit ETH via SETH, send SETH to caller, attribute mint to this app.
     */
    function deposit() public payable {
        if (msg.value == 0) revert InvalidAmount();

        uint256 sethAmount = seth.deposit{ value: msg.value }();
        IERC20(address(seth)).safeTransfer(msg.sender, sethAmount);

        totalMinted += sethAmount;
        registry.recordMint(sethAmount);

        emit Minted(msg.sender, msg.value, sethAmount);
    }

    /**
     * @notice Pull SETH from caller, redeem via SETH, forward ETH, debit `netMinted`.
     */
    function withdraw(
        uint256 sethAmount
    ) external {
        if (sethAmount == 0) revert InvalidAmount();

        uint256 exchangeRate = seth.EXCHANGE_RATE();
        // forge-lint: disable-next-line(divide-before-multiply) - match SETH floor-rounding
        uint256 amountToBurn = (sethAmount / exchangeRate) * exchangeRate;
        if (amountToBurn == 0) revert InvalidAmount();

        IERC20(address(seth)).safeTransferFrom(msg.sender, address(this), amountToBurn);

        uint256 ethOut = seth.withdraw(amountToBurn);
        registry.recordBurn(amountToBurn);

        (bool ok,) = msg.sender.call{ value: ethOut }("");
        if (!ok) revert EthTransferFailed();

        emit Burned(msg.sender, amountToBurn, ethOut);
    }

    // --------------------------------------------
    //  Claim PBR for Registered App
    // --------------------------------------------

    function claim(
        uint64 epochId
    ) external onlyBeneficiary returns (uint256 payout) {
        address treasury = registry.pbrTreasury();
        if (treasury == address(0)) revert TreasuryNotSet();

        payout = IPBRTreasury(treasury).claim(appId, epochId, msg.sender);
        emit YieldClaimed(msg.sender, epochId, payout);
    }

    function claimAll(
        uint64 fromEpoch
    ) external onlyBeneficiary returns (uint256 totalPayout, uint64 nextEpoch) {
        address treasury = registry.pbrTreasury();
        if (treasury == address(0)) revert TreasuryNotSet();

        (totalPayout, nextEpoch) = IPBRTreasury(treasury).claimAll(appId, msg.sender, fromEpoch);
        if (totalPayout != 0) emit YieldClaimed(msg.sender, fromEpoch, totalPayout);
    }
}
