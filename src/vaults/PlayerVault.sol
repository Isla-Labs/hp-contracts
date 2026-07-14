// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { IAdvancedTradeVault } from "../markets/advanced-updated/interfaces/IAdvancedTradeVault.sol";
import { IPlayerVault } from "./interfaces/IPlayerVault.sol";
import { StakedToken } from "./tokens/StakedToken.sol";

/**
 * @title PlayerVault
 * @notice Per-market PBR staking custody. Holds player tokens; mints 1:1 stToken receipts.
 * @dev Users who want AdvancedTrade exposure unstake and open positions manually.
 *      Exclusivity: cannot stake while the account has AT long escrow; AT `openLongTokens`
 *      refuses accounts with `stakedBalance > 0`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVault is IPlayerVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable owner;
    address public immutable override playerToken;
    StakedToken public immutable stakedToken;
    address public override advancedTradeVault;

    /// @notice Matchweek utilization flag for PBR `M_adj` (unsubscribed vaults).
    bool public override isUtilized;

    /**
     * @param owner_ LifecycleTimelock (or test harness).
     * @param playerToken_ Market ERC20 this vault stakes.
     */
    constructor(address owner_, address playerToken_) {
        if (owner_ == address(0) || playerToken_ == address(0)) revert ZeroAddress();
        owner = owner_;
        playerToken = playerToken_;

        string memory sym = _safeSymbol(playerToken_);
        stakedToken = new StakedToken(string.concat("Staked ", sym), string.concat("st", sym), address(this));
        isUtilized = true;
    }

    /// @inheritdoc IPlayerVault
    function stToken() external view override returns (address) {
        return address(stakedToken);
    }

    /// @inheritdoc IPlayerVault
    function stakedBalance(address account) external view override returns (uint256) {
        return stakedToken.balanceOf(account);
    }

    /// @inheritdoc IPlayerVault
    function totalStaked() external view override returns (uint256) {
        return stakedToken.totalSupply();
    }

    /// @inheritdoc IPlayerVault
    function stake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireNotEscrowed(msg.sender);

        IERC20(playerToken).safeTransferFrom(msg.sender, address(this), amount);
        stakedToken.mint(msg.sender, amount);

        emit Staked(msg.sender, amount);
    }

    /// @inheritdoc IPlayerVault
    function unstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakedToken.balanceOf(msg.sender) < amount) revert InsufficientStake();

        stakedToken.burn(msg.sender, amount);
        IERC20(playerToken).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /// @inheritdoc IPlayerVault
    function setAdvancedTradeVault(address vault) external override {
        _onlyOwner();
        address previous = advancedTradeVault;
        advancedTradeVault = vault;
        emit AdvancedTradeVaultUpdated(previous, vault);
    }

    /// @inheritdoc IPlayerVault
    function setUtilized(bool utilized) external override {
        _onlyOwner();
        isUtilized = utilized;
        emit UtilizedUpdated(utilized);
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _requireNotEscrowed(address account) internal view {
        address atv = advancedTradeVault;
        if (atv == address(0)) return;
        if (IAdvancedTradeVault(atv).accountLongSize(account) > 0) revert EscrowedInAdvancedTrade();
    }

    function _safeSymbol(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory sym) {
            if (bytes(sym).length == 0) return "PLY";
            return sym;
        } catch {
            return "PLY";
        }
    }
}
