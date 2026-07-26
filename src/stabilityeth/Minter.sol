// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { IAppRegistry } from "@stabilityeth/base/interfaces/IAppRegistry.sol";
import { IPBRTreasury } from "@stabilityeth/base/interfaces/IPBRTreasury.sol";
import { SETH } from "@stabilityeth/SETH.sol";

/**
 * @title Minter
 * @notice Thin mint/burn router for one `appId`. Credits registry mint stats for CRE / PBR.
 * @dev Beacon-proxy per app. `AppRegistry.totalMinted` / `netMinted` are the canonical store;
 *      local `totalMinted` mirrors cumulative mints for convenience.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract Minter is Initializable {
    /// @notice StabilityETH wrapper
    SETH public seth;

    /// @notice Canonical app identity in `AppRegistry`
    bytes32 public appId;

    /// @notice Registry that deployed this proxy
    IAppRegistry public registry;

    /// @notice Cumulative SETH minted through this minter (mirrors `AppRegistry.totalMinted`)
    uint256 public totalMinted;

    event Minted(address indexed user, uint256 ethIn, uint256 sethAmount);
    event Burned(address indexed user, uint256 sethAmount, uint256 ethOut);
    event YieldClaimed(address indexed beneficiary, uint64 indexed epochId, uint256 amount);

    error ZeroAddress();
    error ZeroAppId();
    error InvalidAmount();
    error NotBeneficiary();
    error TreasuryNotSet();

    modifier onlyBeneficiary() {
        if (!registry.isBeneficiary(appId, msg.sender)) revert NotBeneficiary();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param seth_ StabilityETH wrapper.
     * @param appId_ App identity from `AppRegistry.register`.
     * @param registry_ `AppRegistry` that created this proxy.
     */
    function initialize(address seth_, bytes32 appId_, address registry_) external initializer {
        if (seth_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        if (appId_ == bytes32(0)) revert ZeroAppId();
        seth = SETH(payable(seth_));
        appId = appId_;
        registry = IAppRegistry(registry_);
    }

    /// @notice Bare ETH transfers mint SETH to the sender through this minter
    receive() external payable {
        deposit();
    }

    /**
     * @notice Deposit ETH and mint SETH to the caller; credits registry `totalMinted` / `netMinted`.
     */
    function deposit() public payable {
        if (msg.value == 0) revert InvalidAmount();

        uint256 sethAmount = seth.mintTo{ value: msg.value }(msg.sender);
        totalMinted += sethAmount;
        registry.recordMint(sethAmount);

        emit Minted(msg.sender, msg.value, sethAmount);
    }

    /**
     * @notice Burn caller's SETH and redeem ETH; debits registry `netMinted`.
     * @dev Cumulative `totalMinted` is unchanged — CRE mint-delta uses the cumulative series.
     */
    function withdraw(
        uint256 sethAmount
    ) external {
        if (sethAmount == 0) revert InvalidAmount();

        uint256 exchangeRate = seth.EXCHANGE_RATE();
        // forge-lint: disable-next-line(divide-before-multiply) - match SETH floor-rounding
        uint256 amountToBurn = (sethAmount / exchangeRate) * exchangeRate;
        if (amountToBurn == 0) revert InvalidAmount();

        uint256 ethOut = seth.burnFrom(msg.sender, msg.sender, sethAmount);
        registry.recordBurn(amountToBurn);

        emit Burned(msg.sender, amountToBurn, ethOut);
    }

    /**
     * @notice Claim this beneficiary's share of app yield for `epochId`.
     */
    function claim(
        uint64 epochId
    ) external onlyBeneficiary returns (uint256 payout) {
        address treasury = registry.pbrTreasury();
        if (treasury == address(0)) revert TreasuryNotSet();

        payout = IPBRTreasury(treasury).claim(appId, epochId, msg.sender);
        emit YieldClaimed(msg.sender, epochId, payout);
    }

    /**
     * @notice Claim unpaid daily epochs from `fromEpoch` (batched). Resume with returned `nextEpoch`.
     */
    function claimAll(
        uint64 fromEpoch
    ) external onlyBeneficiary returns (uint256 totalPayout, uint64 nextEpoch) {
        address treasury = registry.pbrTreasury();
        if (treasury == address(0)) revert TreasuryNotSet();

        (totalPayout, nextEpoch) = IPBRTreasury(treasury).claimAll(appId, msg.sender, fromEpoch);
        if (totalPayout != 0) emit YieldClaimed(msg.sender, fromEpoch, totalPayout);
    }
}
