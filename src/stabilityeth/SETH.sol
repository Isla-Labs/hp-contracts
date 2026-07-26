// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @title SETH | StabilityETH
 * @notice Immutable 1:100 ETH wrapper with a 0.1% mint/burn fee to `feeCollector` (PBRTreasury).
 * @dev No minter ACL — anyone may `deposit` / `withdraw`. Apps optionally route through their
 *      `Minter` (deposit → transfer SETH out; pull SETH → withdraw → forward ETH) to attribute volume.
 *      Reentrancy: `_burn` / fee accounting run before the ETH transfer.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract SETH is ERC20 {
    // --------------------------------------------
    //  State Variables
    // --------------------------------------------

    /// @notice 100 SETH per 1 ETH
    uint256 public constant EXCHANGE_RATE = 100;

    /// @notice 0.1% fee on mint and burn
    uint256 public constant FEE_BPS = 10;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Ringfenced ETH fees awaiting PBR distribution (never part of redeemable collateral)
    uint256 public feeAccrued;

    /// @notice Immutable PBR treasury that may `collectFees` (set at deploy)
    address public immutable feeCollector;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event Deposit(address indexed dst, uint256 ethAmount, uint256 sethAmount, uint256 fee);
    event Withdrawal(address indexed src, uint256 sethAmount, uint256 ethAmount, uint256 fee);
    event FeesCollected(address indexed to, uint256 amount);

    error InvalidAmount();
    error EthTransferFailed();
    error NotFeeCollector();
    error ZeroAddress();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param feeCollector_ PBRTreasury (or proxy) address — immutable fee sink authority.
     */
    constructor(
        address feeCollector_
    ) ERC20("StabilityETH", "SETH") {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        feeCollector = feeCollector_;
    }

    // --------------------------------------------
    //  Deposit / Withdraw
    // --------------------------------------------

    /// @notice Bare ETH transfers route into `deposit()`
    receive() external payable {
        deposit();
    }

    /**
     * @notice Mints SETH to the caller at 100:1 after the 0.1% fee.
     * @return sethAmount SETH minted to `msg.sender`.
     */
    function deposit() public payable returns (uint256 sethAmount) {
        if (msg.value == 0) revert InvalidAmount();
        sethAmount = _mintWithFee(msg.sender, msg.value);
    }

    /**
     * @notice Burns caller's SETH and redeems ETH to the caller after the 0.1% fee.
     * @dev Rounds the burn down to a multiple of `EXCHANGE_RATE`. Sub-rate dust stays with the caller.
     * @return ethOut ETH sent to `msg.sender`.
     */
    function withdraw(
        uint256 sethAmount
    ) external returns (uint256 ethOut) {
        ethOut = _burnWithFee(msg.sender, msg.sender, sethAmount);
    }

    // --------------------------------------------
    //  PBR Routing for dApps
    // --------------------------------------------

    /**
     * @notice Moves ringfenced fees to `to` for PBR distribution.
     * @dev Only `feeCollector`. Never dips into redeemable collateral.
     */
    function collectFees(address to, uint256 amount) external {
        if (msg.sender != feeCollector) revert NotFeeCollector();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > feeAccrued) revert InvalidAmount();

        uint256 redeemable = _redeemableEth(totalSupply());
        if (address(this).balance - amount < redeemable) revert InvalidAmount();

        feeAccrued -= amount;

        (bool success,) = to.call{ value: amount }("");
        if (!success) revert EthTransferFailed();

        emit FeesCollected(to, amount);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @notice ETH required to fully redeem the current SETH supply at 1:100
    function redeemableCollateral() public view returns (uint256) {
        return _redeemableEth(totalSupply());
    }

    /// @notice ETH collateral held by the wrapper (redeemable + ringfenced fees + dust)
    function ethCollateral() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Whether the contract holds enough ETH to fully redeem the current SETH supply
    function isFullyBacked() external view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        return address(this).balance * EXCHANGE_RATE >= supply;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _mintWithFee(address to, uint256 ethIn) internal returns (uint256 sethAmount) {
        uint256 fee = (ethIn * FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = ethIn - fee;
        if (net == 0) revert InvalidAmount();

        sethAmount = net * EXCHANGE_RATE;
        feeAccrued += fee;

        _mint(to, sethAmount);
        emit Deposit(to, ethIn, sethAmount, fee);
    }

    function _burnWithFee(
        address from,
        address to,
        uint256 sethAmount
    ) internal returns (uint256 ethOut) {
        if (sethAmount < EXCHANGE_RATE) revert InvalidAmount();

        // forge-lint: disable-next-line(divide-before-multiply) - intentional floor-rounding to a multiple of EXCHANGE_RATE
        uint256 amountToBurn = (sethAmount / EXCHANGE_RATE) * EXCHANGE_RATE;
        uint256 ethGross = amountToBurn / EXCHANGE_RATE;
        uint256 fee = (ethGross * FEE_BPS) / BPS_DENOMINATOR;
        ethOut = ethGross - fee;

        _burn(from, amountToBurn);
        feeAccrued += fee;

        (bool success,) = to.call{ value: ethOut }("");
        if (!success) revert EthTransferFailed();

        emit Withdrawal(from, amountToBurn, ethOut, fee);
    }

    function _redeemableEth(
        uint256 supply
    ) internal pure returns (uint256) {
        return supply / EXCHANGE_RATE;
    }
}
