// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IFundingController
 * @notice Phase 2 singleton: FMV gap, budgeted FRT drip, per-market / per-side funding indices.
 * @dev Phase 1 vaults may point here at address(0). When live, vaults checkpoint on open/close/claim.
 *      FMV is reward weighting + UI only — never margin, liquidation, or settlement input.
 */
interface IFundingController {
    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event MarketRegistered(address indexed vault, address indexed playerToken);
    event MarketPaused(address indexed vault, bool paused);
    event GlobalPaused(bool paused);
    event Remarque(address indexed vault, int256 gap, uint256 marketRate, uint256 timestamp);
    event FundingClaimed(address indexed vault, address indexed user, uint256 amount);
    event DripReset(uint256 budgetPerSecond, uint256 runway, uint256 timestamp);
    event FeesReceived(address indexed from, uint256 amount);

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error NotVault();
    error MarketNotRegistered();
    error FundingPaused();
    error Wireframe();

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function isPaused() external view returns (bool);
    function isMarketPaused(address vault) external view returns (bool);
    function gap(address vault) external view returns (int256);
    function marketRate(address vault) external view returns (uint256);
    function rewardPerToken(address vault, bool isLong) external view returns (uint256);
    function pendingFunding(address vault, address user) external view returns (uint256);
    function frtBalance() external view returns (uint256);

    // --------------------------------------------
    //  Vault hooks (called by AdvancedTradeVault)
    // --------------------------------------------

    function registerMarket(address vault, address playerToken) external;
    function checkpoint(address vault, address user, bool isLong, uint256 sizeBefore, uint256 sizeAfter) external;
    function claim(address vault, address user) external returns (uint256 amount);

    // --------------------------------------------
    //  Keepers / permissionless
    // --------------------------------------------

    /// @notice Re-mark gap + rates for a market (permissionless poke).
    function remarque(address vault) external;

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function pauseGlobal(bool paused) external;
    function pauseMarket(address vault, bool paused) external;
    function resetDrip(uint256 runwaySeconds) external;

    /// @notice Receive ETH fee share from FeeRouter (`atFunding`).
    receive() external payable;
}
