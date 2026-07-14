// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import {
    BorrowCurve,
    LongCloseMode,
    MarginParams,
    Position,
    Side,
    SlippageBound,
    VaultInitParams
} from "../types/AdvancedTradeTypes.sol";

/**
 * @title IAdvancedTradeVault
 * @notice Per-market AdvancedTrade surface: escrowed longs, inventory shorts, borrow fees, liquidations.
 * @dev Phase 1 self-sustaining. Phase 2 funding checkpoints are no-ops until `fundingController` is set.
 */
interface IAdvancedTradeVault {
    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event VaultInitialized(
        address indexed playerToken, address indexed collateral, uint256 seededInventory, address owner
    );
    event LongOpened(
        uint256 indexed positionId, address indexed owner, uint256 size, uint256 entryMark, uint8 openMode
    );
    event ShortOpened(
        uint256 indexed positionId,
        address indexed owner,
        uint256 size,
        uint256 collateral,
        uint256 saleProceeds,
        uint256 entryMark
    );
    event PositionClosed(uint256 indexed positionId, address indexed owner, Side side, int256 pnl);
    event PositionLiquidated(
        uint256 indexed positionId, address indexed owner, address indexed liquidator, uint256 bounty, uint256 insurance
    );
    event BorrowFeeAccrued(uint256 indexed positionId, uint256 feeAmount, uint256 utilization);
    event InventoryExpanded(uint256 previousSize, uint256 newSize);
    event InventoryWrittenOff(uint256 amount, uint256 remainingInventorySize);
    event MarkUpdated(uint256 mark, uint256 spot, uint256 timestamp);
    event FundingControllerUpdated(address indexed previous, address indexed next);
    event SwapRouterUpdated(address indexed previous, address indexed next);
    event MarkSourceUpdated(address indexed previous, address indexed next);
    event PlayerVaultUpdated(address indexed previous, address indexed next);
    event ImpactEstimatorUpdated(address indexed previous, address indexed next);
    event ParamsUpdated();
    event FundingClaimed(address indexed user, uint256 amount);

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ZeroSlippageBound();
    error DeadlineExpired();
    error NotOwner();
    error NotPositionOwner();
    error PositionNotOpen();
    error InvalidSide();
    error InventoryHardCap();
    error InsufficientInventory();
    error AccountShortCap();
    error InsufficientMargin();
    error NotLiquidatable();
    error CloseImpactTooHigh();
    error MarkNotReady();
    error SwapRouterNotSet();
    error SlippageExceeded();
    error StakedInPlayerVault();
    error Wireframe(); // residual stubs only

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function playerToken() external view returns (address);
    function collateral() external view returns (address);
    function fundingController() external view returns (address);
    function inventorySize() external view returns (uint256);
    function shortOpenInterest() external view returns (uint256);
    function idleInventory() external view returns (uint256);
    function utilization() external view returns (uint256);
    function markPrice() external view returns (uint256);
    function nextPositionId() external view returns (uint256);
    function getPosition(uint256 positionId) external view returns (Position memory);
    function positionsOf(address owner) external view returns (uint256[] memory);
    function borrowCurve() external view returns (BorrowCurve memory);
    function marginParams() external view returns (MarginParams memory);
    function insuranceBuffer() external view returns (uint256);
    function isLiquidatable(uint256 positionId) external view returns (bool);

    // --------------------------------------------
    //  Lifecycle — Long
    // --------------------------------------------

    /// @notice Open long: swap `usdcIn` → player tokens into escrow (funding-eligible).
    function openLongUsdc(uint256 usdcIn, SlippageBound calldata bound)
        external
        returns (uint256 positionId, uint256 size);

    /// @notice Open long: deposit already-held player tokens into escrow (rotation path).
    function openLongTokens(uint256 tokenAmount) external returns (uint256 positionId);

    /// @notice Close long via sell-to-USDC or return-tokens.
    function closeLong(uint256 positionId, LongCloseMode mode, SlippageBound calldata bound)
        external
        returns (uint256 amountOut);

    // --------------------------------------------
    //  Lifecycle — Short
    // --------------------------------------------

    /// @notice Open inventory-backed short: escrow USDC collateral, sell `size` from inventory.
    function openShort(uint256 size, uint256 collateralIn, SlippageBound calldata bound)
        external
        returns (uint256 positionId, uint256 saleProceeds);

    /// @notice Close short: buy back `size`, settle PnL against escrow + proceeds, restore inventory.
    function closeShort(uint256 positionId, SlippageBound calldata bound) external returns (int256 pnl);

    // --------------------------------------------
    //  Fees / liquidations / marks
    // --------------------------------------------

    /// @notice Accrue borrow fee against a short's escrow (permissionless / on interaction).
    function accrueBorrowFee(uint256 positionId) external returns (uint256 feeAmount);

    /// @notice Liquidate an underwater short; bounty to caller, slice to insurance.
    function liquidate(uint256 positionId, SlippageBound calldata bound) external;

    /// @notice Refresh EMA mark from pool (permissionless poke).
    function updateMark() external returns (uint256 mark);

    /// @notice Claim accrued Phase 2 funding for caller via FundingController.
    function claimFunding() external returns (uint256 amount);

    // --------------------------------------------
    //  Admin / governance
    // --------------------------------------------

    function initialize(VaultInitParams calldata params) external;

    /// @notice Expand inventorySize toward INVENTORY_HARD_CAP (Phase 3 lending; tokens pulled from `from`).
    function expandInventory(uint256 amount, address from) external;

    function setFundingController(address fundingController_) external;
    function setBorrowCurve(BorrowCurve calldata curve) external;
    function setMarginParams(MarginParams calldata params) external;
    function setPbrTreasury(address pbrTreasury_) external;
    function setSwapRouter(address swapRouter_) external;
    function setMarkSource(address markSource_) external;
    function setMarkHalfLife(uint256 halfLifeSeconds) external;
    function setPlayerVault(address playerVault_) external;
    function setImpactEstimator(address impactEstimator_) external;

    /// @notice End-of-call invariant check (also invoked internally after state mutations).
    function assertInvariants() external view;
}
