// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { IFundingController } from "./interfaces/IFundingController.sol";

/**
 * @title FundingController
 * @notice Phase 2 singleton: FRT custody, drip budget, per-market gap state and funding indices.
 * @dev Wireframe. Receives FeeRouter's FR share (`atFunding`). FMV never feeds margin/liquidation.
 *
 *      Accrual: Synthetix-style rewardPerToken per market per side; claim-based, zero-floored.
 *      Kill switches pause accrual only — Phase 1 vault ops continue.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FundingController is IFundingController, Ownable2Step, ReentrancyGuard {
    // --------------------------------------------
    //  Global state
    // --------------------------------------------

    bool public override isPaused;
    uint256 public dripPerSecond;
    uint256 public dripUpdatedAt;
    uint256 public totalScore; // Σ |g_i| post clamp/deadband

    mapping(address vault => bool registered) public registered;
    mapping(address vault => bool paused) internal _marketPaused;
    mapping(address vault => address playerToken) public vaultMarket;
    mapping(address vault => int256 gapWad) internal _gap;
    mapping(address vault => uint256 rate) internal _marketRate;
    mapping(address vault => mapping(bool isLong => uint256 rpt)) internal _rewardPerToken;
    mapping(address vault => mapping(address user => mapping(bool isLong => uint256 checkpoint))) internal _checkpoint;
    mapping(address vault => mapping(address user => uint256 accrued)) internal _accrued;

    // --------------------------------------------
    //  Init
    // --------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    // --------------------------------------------
    //  Receive fees (FeeRouter → atFunding)
    // --------------------------------------------

    /// @inheritdoc IFundingController
    receive() external payable override {
        emit FeesReceived(msg.sender, msg.value);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IFundingController
    function isMarketPaused(address vault) external view override returns (bool) {
        return _marketPaused[vault];
    }

    /// @inheritdoc IFundingController
    function gap(address vault) external view override returns (int256) {
        return _gap[vault];
    }

    /// @inheritdoc IFundingController
    function marketRate(address vault) external view override returns (uint256) {
        return _marketRate[vault];
    }

    /// @inheritdoc IFundingController
    function rewardPerToken(address vault, bool isLong) external view override returns (uint256) {
        return _rewardPerToken[vault][isLong];
    }

    /// @inheritdoc IFundingController
    function pendingFunding(address vault, address user) external view override returns (uint256) {
        return _accrued[vault][user];
    }

    /// @inheritdoc IFundingController
    function frtBalance() external view override returns (uint256) {
        return address(this).balance;
    }

    // --------------------------------------------
    //  Vault hooks
    // --------------------------------------------

    /// @inheritdoc IFundingController
    function registerMarket(address vault, address playerToken) external override onlyOwner {
        if (vault == address(0) || playerToken == address(0)) revert ZeroAddress();
        registered[vault] = true;
        vaultMarket[vault] = playerToken;
        emit MarketRegistered(vault, playerToken);
    }

    /// @inheritdoc IFundingController
    function checkpoint(address vault, address user, bool isLong, uint256 sizeBefore, uint256 sizeAfter)
        external
        override
    {
        if (!registered[vault]) revert MarketNotRegistered();
        if (msg.sender != vault) revert NotVault();
        // Settle accrued from rewardPerToken delta × sizeBefore; update checkpoint; adjust side OI
        sizeBefore;
        sizeAfter;
        isLong;
        user;
        revert Wireframe();
    }

    /// @inheritdoc IFundingController
    function claim(address vault, address user) external override nonReentrant returns (uint256 amount) {
        if (!registered[vault]) revert MarketNotRegistered();
        if (isPaused || _marketPaused[vault]) revert FundingPaused();
        // Pay USDC/ETH from FRT; zero-floored
        user;
        revert Wireframe();
    }

    // --------------------------------------------
    //  Keepers
    // --------------------------------------------

    /// @inheritdoc IFundingController
    function remarque(address vault) external override {
        if (!registered[vault]) revert MarketNotRegistered();
        // Settle accumulators → refresh liq EMA from pool → recompute g_i / rates / Σ score
        revert Wireframe();
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /// @inheritdoc IFundingController
    function pauseGlobal(bool paused) external override onlyOwner {
        isPaused = paused;
        emit GlobalPaused(paused);
    }

    /// @inheritdoc IFundingController
    function pauseMarket(address vault, bool paused) external override onlyOwner {
        if (!registered[vault]) revert MarketNotRegistered();
        _marketPaused[vault] = paused;
        emit MarketPaused(vault, paused);
    }

    /// @inheritdoc IFundingController
    function resetDrip(uint256 runwaySeconds) external override onlyOwner {
        if (runwaySeconds == 0) revert Wireframe();
        uint256 bal = address(this).balance;
        dripPerSecond = bal / runwaySeconds;
        dripUpdatedAt = block.timestamp;
        emit DripReset(dripPerSecond, runwaySeconds, block.timestamp);
    }
}
