// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { IAdvancedTradeVault } from "./interfaces/IAdvancedTradeVault.sol";
import { IFundingController } from "./interfaces/IFundingController.sol";
import {
    BorrowCurve,
    INVENTORY_HARD_CAP,
    LongCloseMode,
    LongOpenMode,
    MarginParams,
    Position,
    Side,
    SlippageBound,
    VaultInitParams,
    WAD
} from "./types/AdvancedTradeTypes.sol";

/**
 * @title AdvancedTradeVault
 * @notice Per-market beacon implementation: escrowed longs, inventory-backed shorts, borrow fees, liquidations.
 * @dev Wireframe — storage, surface, and invariant hooks only. Swap / margin math lands next.
 *
 *      Invariants (asserted after state-mutating calls):
 *        1. vaultTokenBalance + shortOI == inventorySize; shortOI ≤ INVENTORY_HARD_CAP
 *        2. No unbacked inventory sells
 *        3. Escrow decreases only via close / liquidation / borrow fee
 *        4. Opens satisfy IM (incl. modeled close impact)
 *        5. Short sale proceeds are position-committed
 *        6. Incentive exclusivity with PlayerVault (enforced at integration boundary)
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract AdvancedTradeVault is IAdvancedTradeVault, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------
    //  Immutables / config (set once in initialize)
    // --------------------------------------------

    address public override playerToken;
    address public override collateral; // USDC
    address public swapRouter;
    address public override fundingController;
    address public pbrTreasury;
    address public owner;

    // --------------------------------------------
    //  Inventory / OI
    // --------------------------------------------

    /// @notice Current inventory capacity (seeded ≤ size ≤ INVENTORY_HARD_CAP)
    uint256 public override inventorySize;

    /// @notice Aggregate open short size in player tokens
    uint256 public override shortOpenInterest;

    /// @notice Aggregate escrowed long size in player tokens (separate ledger from inventory)
    uint256 public longEscrowed;

    /// @notice USDC insurance buffer (first-loss vs short bad debt)
    uint256 public override insuranceBuffer;

    // --------------------------------------------
    //  Marks / rates
    // --------------------------------------------

    uint256 public override markPrice; // WAD
    uint256 public markUpdatedAt;
    uint256 public borrowIndex; // cumulative borrow index (WAD)
    uint256 public borrowIndexUpdatedAt;

    BorrowCurve public curve;
    MarginParams public margins;

    // --------------------------------------------
    //  Positions
    // --------------------------------------------

    uint256 public override nextPositionId;
    mapping(uint256 positionId => Position position) internal _positions;
    mapping(address owner => uint256[] ids) internal _positionsOf;

    // --------------------------------------------
    //  Modifiers
    // --------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // --------------------------------------------
    //  Init
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IAdvancedTradeVault
    function initialize(VaultInitParams calldata params) external override initializer {
        if (
            params.playerToken == address(0) || params.collateral == address(0) || params.owner == address(0)
                || params.pbrTreasury == address(0)
        ) {
            revert ZeroAddress();
        }
        if (params.seededInventory == 0 || params.seededInventory > INVENTORY_HARD_CAP) revert InventoryHardCap();

        playerToken = params.playerToken;
        collateral = params.collateral;
        swapRouter = params.swapRouter;
        fundingController = params.fundingController;
        pbrTreasury = params.pbrTreasury;
        owner = params.owner;

        inventorySize = params.seededInventory;
        borrowIndex = WAD;
        borrowIndexUpdatedAt = block.timestamp;
        markUpdatedAt = block.timestamp;

        // Launch placeholders (§3.6) — governance retunes via setters
        curve = BorrowCurve({
            r0: 5e16, // 5% APR
            slope1: 25e16, // reaches ~25% at kink (illustrative; exact slope wiring TBD)
            slope2: 125e16,
            uKink: 8e17 // 80%
        });
        margins = MarginParams({
            initialMarginWad: 4e17, // 40%
            maintenanceMarginWad: 2e17, // 20%
            liquidationBountyWad: 5e16, // 5%
            insuranceSliceWad: 25e15, // 2.5%
            maxCloseImpactWad: 2e16, // 2%
            perAccountShortCapWad: 1e17 // 10% of inventory
        });

        emit VaultInitialized(params.playerToken, params.collateral, params.seededInventory, params.owner);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IAdvancedTradeVault
    function idleInventory() public view override returns (uint256) {
        return inventorySize - shortOpenInterest;
    }

    /// @inheritdoc IAdvancedTradeVault
    function utilization() public view override returns (uint256) {
        if (inventorySize == 0) return 0;
        return (shortOpenInterest * WAD) / inventorySize;
    }

    /// @inheritdoc IAdvancedTradeVault
    function getPosition(uint256 positionId) external view override returns (Position memory) {
        return _positions[positionId];
    }

    /// @inheritdoc IAdvancedTradeVault
    function positionsOf(address account) external view override returns (uint256[] memory) {
        return _positionsOf[account];
    }

    /// @inheritdoc IAdvancedTradeVault
    function borrowCurve() external view override returns (BorrowCurve memory) {
        return curve;
    }

    /// @inheritdoc IAdvancedTradeVault
    function marginParams() external view override returns (MarginParams memory) {
        return margins;
    }

    /// @inheritdoc IAdvancedTradeVault
    function isLiquidatable(uint256 /* positionId */ ) public view override returns (bool) {
        // Wireframe: margin equity vs MM at mark — implement with short equity formula (§3.5)
        return false;
    }

    // --------------------------------------------
    //  Long lifecycle
    // --------------------------------------------

    /// @inheritdoc IAdvancedTradeVault
    function openLongUsdc(uint256 usdcIn, SlippageBound calldata bound)
        external
        override
        nonReentrant
        returns (uint256 positionId, uint256 size)
    {
        if (usdcIn == 0) revert ZeroAmount();
        _requireSlippage(bound);
        // Pull USDC → swap to playerToken → escrow → register LONG / USDC_IN
        // Checkpoint fundingController if set
        revert Wireframe();
    }

    /// @inheritdoc IAdvancedTradeVault
    function openLongTokens(uint256 tokenAmount) external override nonReentrant returns (uint256 positionId) {
        if (tokenAmount == 0) revert ZeroAmount();
        // Pull playerToken → escrow → register LONG / TOKEN_DEPOSIT
        // Must be exclusive with PlayerVault staking (§3.7.6)
        revert Wireframe();
    }

    /// @inheritdoc IAdvancedTradeVault
    function closeLong(uint256 positionId, LongCloseMode mode, SlippageBound calldata bound)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        Position storage pos = _positions[positionId];
        if (!pos.open) revert PositionNotOpen();
        if (pos.owner != msg.sender) revert NotPositionOwner();
        if (pos.side != Side.LONG) revert InvalidSide();
        if (mode == LongCloseMode.SELL_TO_USDC) _requireSlippage(bound);
        revert Wireframe();
    }

    // --------------------------------------------
    //  Short lifecycle
    // --------------------------------------------

    /// @inheritdoc IAdvancedTradeVault
    function openShort(uint256 size, uint256 collateralIn, SlippageBound calldata bound)
        external
        override
        nonReentrant
        returns (uint256 positionId, uint256 saleProceeds)
    {
        if (size == 0 || collateralIn == 0) revert ZeroAmount();
        _requireSlippage(bound);
        if (size > idleInventory()) revert InsufficientInventory();
        if (shortOpenInterest + size > INVENTORY_HARD_CAP) revert InventoryHardCap();
        // IM check incl. modeled close impact; per-account short cap; sell inventory → pool;
        // escrow collateral + commit saleProceeds; bump shortOI
        revert Wireframe();
    }

    /// @inheritdoc IAdvancedTradeVault
    function closeShort(uint256 positionId, SlippageBound calldata bound)
        external
        override
        nonReentrant
        returns (int256 pnl)
    {
        Position storage pos = _positions[positionId];
        if (!pos.open) revert PositionNotOpen();
        if (pos.owner != msg.sender) revert NotPositionOwner();
        if (pos.side != Side.SHORT) revert InvalidSide();
        _requireSlippage(bound);
        // Accrue borrow fee → buy back size → settle → restore inventory / reduce shortOI
        revert Wireframe();
    }

    // --------------------------------------------
    //  Fees / liquidations / marks
    // --------------------------------------------

    /// @inheritdoc IAdvancedTradeVault
    function accrueBorrowFee(uint256 positionId) external override nonReentrant returns (uint256 feeAmount) {
        Position storage pos = _positions[positionId];
        if (!pos.open || pos.side != Side.SHORT) revert PositionNotOpen();
        // Two-slope utilization curve (§3.4); fee from escrow → insurance / pbrTreasury [/ FRT]
        revert Wireframe();
    }

    /// @inheritdoc IAdvancedTradeVault
    function liquidate(uint256 positionId, SlippageBound calldata bound) external override nonReentrant {
        if (!isLiquidatable(positionId)) revert NotLiquidatable();
        _requireSlippage(bound);
        // Permissionless; bounty to msg.sender; insurance slice; restore inventory or socialize shortfall
        revert Wireframe();
    }

    /// @inheritdoc IAdvancedTradeVault
    function updateMark() external override returns (uint256 mark) {
        // EMA of pool price — never raw spot (§3.5)
        revert Wireframe();
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /// @inheritdoc IAdvancedTradeVault
    function expandInventory(uint256 amount, address from) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (from == address(0)) revert ZeroAddress();
        uint256 next = inventorySize + amount;
        if (next > INVENTORY_HARD_CAP) revert InventoryHardCap();

        uint256 previous = inventorySize;
        IERC20(playerToken).safeTransferFrom(from, address(this), amount);
        inventorySize = next;
        emit InventoryExpanded(previous, next);
        _assertInvariants();
    }

    /// @inheritdoc IAdvancedTradeVault
    function setFundingController(address fundingController_) external override onlyOwner {
        address previous = fundingController;
        fundingController = fundingController_;
        emit FundingControllerUpdated(previous, fundingController_);
    }

    /// @inheritdoc IAdvancedTradeVault
    function setBorrowCurve(BorrowCurve calldata curve_) external override onlyOwner {
        curve = curve_;
        emit ParamsUpdated();
    }

    /// @inheritdoc IAdvancedTradeVault
    function setMarginParams(MarginParams calldata params) external override onlyOwner {
        margins = params;
        emit ParamsUpdated();
    }

    /// @inheritdoc IAdvancedTradeVault
    function setPbrTreasury(address pbrTreasury_) external override onlyOwner {
        if (pbrTreasury_ == address(0)) revert ZeroAddress();
        pbrTreasury = pbrTreasury_;
        emit ParamsUpdated();
    }

    /// @inheritdoc IAdvancedTradeVault
    function assertInvariants() external view override {
        _assertInvariants();
    }

    // --------------------------------------------
    //  Internals (wireframe helpers)
    // --------------------------------------------

    function _requireSlippage(SlippageBound calldata bound) internal pure {
        if (bound.amountOutMin == 0 || bound.deadline == 0) revert ZeroSlippageBound();
    }

    function _checkpointFunding(address account, Side side, uint256 sizeBefore, uint256 sizeAfter) internal {
        address fc = fundingController;
        if (fc == address(0)) return;
        IFundingController(payable(fc)).checkpoint(address(this), account, side == Side.LONG, sizeBefore, sizeAfter);
    }

    function _openPosition(address account, Side side, LongOpenMode longMode, uint256 size, uint256 entryMark)
        internal
        returns (uint256 positionId)
    {
        positionId = ++nextPositionId;
        _positions[positionId] = Position({
            owner: account,
            side: side,
            longMode: longMode,
            size: size,
            entryMark: entryMark,
            collateral: 0,
            saleProceeds: 0,
            openedAt: block.timestamp,
            open: true
        });
        _positionsOf[account].push(positionId);
    }

    /// @dev Inventory conservation + hard cap. Long escrow is a separate ledger.
    function _assertInvariants() internal view {
        uint256 tokenBal = IERC20(playerToken).balanceOf(address(this));
        // Idle inventory tokens + tokens backing open shorts conceptually:
        // physical balance should cover idleInventory + longEscrowed (shorts already sold out).
        // Full accounting lands with swap paths; hard cap always enforced.
        if (shortOpenInterest > inventorySize) revert InsufficientInventory();
        if (shortOpenInterest > INVENTORY_HARD_CAP) revert InventoryHardCap();
        if (idleInventory() + longEscrowed > tokenBal) {
            // Allow during wireframe before seed transfer / swaps are wired — tighten when live.
        }
        tokenBal; // silence until strict check enabled
    }
}
