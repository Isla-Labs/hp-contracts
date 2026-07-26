// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { IAppRegistry } from "@stabilityeth/interfaces/IAppRegistry.sol";
import { SETH } from "@stabilityeth/SETH.sol";

/**
 * @title Minter
 * @notice Thin mint/burn router for one `appId`. Credits `totalMinted` for the `s/S` leg.
 * @dev Beacon-proxy per app. Yield claims are gated to `AppRegistry` beneficiaries for this `appId`.
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

    /// @notice Cumulative SETH minted through this minter (app `s`)
    uint256 public totalMinted;

    event Minted(address indexed user, uint256 ethIn, uint256 sethAmount);
    event Burned(address indexed user, uint256 sethAmount, uint256 ethOut);
    event YieldClaimed(address indexed beneficiary, uint256 amount);

    error ZeroAddress();
    error ZeroAppId();
    error InvalidAmount();
    error NotBeneficiary();
    error YieldNotAvailable();

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
     * @notice Deposit ETH and mint SETH to the caller; credits `totalMinted`.
     */
    function deposit() public payable {
        if (msg.value == 0) revert InvalidAmount();

        uint256 sethAmount = seth.mintTo{ value: msg.value }(msg.sender);
        totalMinted += sethAmount;

        emit Minted(msg.sender, msg.value, sethAmount);
    }

    /**
     * @notice Burn caller's SETH and redeem ETH to the caller via this minter.
     * @dev Does not decrease `totalMinted` — `s` is mint-volume based.
     */
    function withdraw(
        uint256 sethAmount
    ) external {
        if (sethAmount == 0) revert InvalidAmount();

        uint256 ethOut = seth.burnFrom(msg.sender, msg.sender, sethAmount);
        emit Burned(msg.sender, sethAmount, ethOut);
    }

    /**
     * @notice Claim this beneficiary's share of app yield.
     * @dev Gated to registry beneficiaries. PBR accrual wiring lands in a later iteration.
     */
    function claim() external onlyBeneficiary {
        revert YieldNotAvailable();
    }
}
