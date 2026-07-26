// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @title SETH | StabilityETH
 * @notice 1:100 ETH wrapper with a 0.1% mint/burn fee ringfenced for app PBR.
 * @dev Direct `deposit` / `withdraw` are unattributed. Registered apps route through
 *      allowlisted `Minter` proxies via `mintTo` / `burnFrom` so their `s` credit can accrue.
 *      Reentrancy: `_burn` / fee accounting run before the ETH transfer.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract SETH is ERC20, Ownable {
    /// @notice 100 SETH per 1 ETH
    uint256 public constant EXCHANGE_RATE = 100;

    /// @notice 0.1% fee on mint and burn
    uint256 public constant FEE_BPS = 10;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Ringfenced ETH fees awaiting PBR distribution (never part of redeemable collateral)
    uint256 public feeAccrued;

    /// @notice Cumulative SETH minted through allowlisted minters (global `S` numerator basis)
    uint256 public totalMinterMinted;

    /// @notice Sole authority to allowlist minters (typically `AppRegistry`)
    address public minterManager;

    /// @notice Pulls ringfenced fees into the PBR distribution path
    address public feeCollector;

    mapping(address account => bool) public isMinter;

    event Deposit(address indexed dst, uint256 ethAmount, uint256 sethAmount, uint256 fee);
    event Withdrawal(address indexed src, uint256 sethAmount, uint256 ethAmount, uint256 fee);
    event MinterUpdated(address indexed minter, bool allowed);
    event MinterManagerUpdated(address indexed minterManager);
    event FeeCollectorUpdated(address indexed feeCollector);
    event FeesCollected(address indexed to, uint256 amount);

    error InvalidAmount();
    error EthTransferFailed();
    error NotMinter();
    error NotMinterManager();
    error NotFeeCollector();
    error ZeroAddress();

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    modifier onlyMinterManager() {
        if (msg.sender != minterManager) revert NotMinterManager();
        _;
    }

    constructor(address owner_) ERC20("StabilityETH", "SETH") Ownable(owner_) { }

    /// @notice Bare ETH transfers route into unattributed `deposit()`
    receive() external payable {
        deposit();
    }

    // --------------------------------------------
    //  Unattributed wrap / unwrap
    // --------------------------------------------

    /**
     * @notice Mints SETH against ETH at 100:1 after the 0.1% fee.
     * @dev Fee is skimmed from `msg.value`; mint amount uses the net ETH.
     */
    function deposit() public payable {
        if (msg.value == 0) revert InvalidAmount();
        _mintWithFee(msg.sender, msg.value, false);
    }

    /**
     * @notice Burns SETH and redeems ETH at 1:100 after the 0.1% fee.
     * @dev Rounds the burn down to a multiple of `EXCHANGE_RATE`. Sub-rate dust stays with the caller.
     */
    function withdraw(
        uint256 sethAmount
    ) external {
        _burnWithFee(msg.sender, msg.sender, sethAmount);
    }

    // --------------------------------------------
    //  Minter-attributed wrap / unwrap
    // --------------------------------------------

    /**
     * @notice Minter-attributed mint: credits `totalMinterMinted` for the `s/S` leg.
     * @return sethAmount SETH minted to `to` after the fee.
     */
    function mintTo(
        address to
    ) external payable onlyMinter returns (uint256 sethAmount) {
        if (to == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidAmount();
        sethAmount = _mintWithFee(to, msg.value, true);
    }

    /**
     * @notice Minter-attributed burn: redeems ETH to `to` after the fee.
     * @return ethOut ETH sent to `to` after the fee.
     */
    function burnFrom(
        address from,
        address to,
        uint256 sethAmount
    ) external onlyMinter returns (uint256 ethOut) {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        ethOut = _burnWithFee(from, to, sethAmount);
    }

    // --------------------------------------------
    //  Admin / fee surface
    // --------------------------------------------

    function setMinterManager(
        address minterManager_
    ) external onlyOwner {
        if (minterManager_ == address(0)) revert ZeroAddress();
        minterManager = minterManager_;
        emit MinterManagerUpdated(minterManager_);
    }

    function setMinter(address minter, bool allowed) external onlyMinterManager {
        if (minter == address(0)) revert ZeroAddress();
        isMinter[minter] = allowed;
        emit MinterUpdated(minter, allowed);
    }

    function setFeeCollector(
        address feeCollector_
    ) external onlyOwner {
        if (feeCollector_ == address(0)) revert ZeroAddress();
        feeCollector = feeCollector_;
        emit FeeCollectorUpdated(feeCollector_);
    }

    /**
     * @notice Moves ringfenced fees out for PBR distribution.
     * @dev Never dips into redeemable collateral backing the SETH supply.
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

    function _mintWithFee(
        address to,
        uint256 ethIn,
        bool attributed
    ) internal returns (uint256 sethAmount) {
        uint256 fee = (ethIn * FEE_BPS) / BPS_DENOMINATOR;
        uint256 net = ethIn - fee;
        if (net == 0) revert InvalidAmount();

        sethAmount = net * EXCHANGE_RATE;
        feeAccrued += fee;

        if (attributed) totalMinterMinted += sethAmount;

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
