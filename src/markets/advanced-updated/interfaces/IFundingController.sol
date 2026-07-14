// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IFundingController
 * @notice Phase 2 singleton: FMV gap, budgeted FRT drip, per-market / per-side funding indices.
 * @dev FMV is reward weighting + UI only — never margin, liquidation, or settlement input.
 *      FRT receives ETH from FeeRouter; claims pay ETH (zero-floored).
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
    event PpmUpdated(address indexed vault, uint256 ppm, uint256 PPM);
    event GraceUpdated(address indexed vault, bool inGrace);
    event ParamsUpdated();

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error NotVault();
    error MarketNotRegistered();
    error FundingPaused();
    error InGrace();
    error TransferFailed();
    error InvalidParam();

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
    function totalPpm() external view returns (uint256);
    function totalLiq() external view returns (uint256);

    // --------------------------------------------
    //  Vault hooks
    // --------------------------------------------

    function registerMarket(address vault, address playerToken) external;
    function checkpoint(address vault, address user, bool isLong, uint256 sizeBefore, uint256 sizeAfter) external;
    function claim(address vault, address user) external returns (uint256 amount);

    // --------------------------------------------
    //  Keepers / permissionless
    // --------------------------------------------

    function remarque(address vault) external;

    // --------------------------------------------
    //  Admin / oracle
    // --------------------------------------------

    function pauseGlobal(bool paused) external;
    function pauseMarket(address vault, bool paused) external;
    function resetDrip(uint256 runwaySeconds) external;
    function setPpm(address vault, uint256 ppm) external;
    function setLiq(address vault, uint256 liq) external;
    function setGrace(address vault, bool inGrace) external;
    function setLiquiditySource(address source) external;
    function setFundingParams(uint256 gMaxWad, uint256 gDeadWad, uint256 rateCapBps, uint256 liqHalfLife)
        external;

    receive() external payable;
}
