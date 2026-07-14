// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { IAdvancedTradeVault } from "./interfaces/IAdvancedTradeVault.sol";
import { IFundingController } from "./interfaces/IFundingController.sol";
import { IImpactEstimator } from "./interfaces/IImpactEstimator.sol";
import { IMarkSource } from "./interfaces/IMarkSource.sol";
import { IPlayerVault } from "./interfaces/IPlayerVault.sol";
import { IVaultSwapRouter } from "./interfaces/IVaultSwapRouter.sol";
import { BorrowMath } from "./libraries/BorrowMath.sol";
import { MarginMath } from "./libraries/MarginMath.sol";
import { MarkMath } from "./libraries/MarkMath.sol";
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
 * @dev Phase 1 logic. Swaps go through `IVaultSwapRouter`; marks via EMA over `IMarkSource` spot.
 *
 *      Inventory invariant: `playerToken.balanceOf(this) + shortOI == inventorySize + longEscrowed`
 *      (sold short tokens leave the vault; long escrow stays).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract AdvancedTradeVault is IAdvancedTradeVault, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    address public override playerToken;
    address public override collateral; // USDC
    address public swapRouter;
    address public markSource;
    address public override fundingController;
    address public pbrTreasury;
    address public playerVault;
    address public impactEstimator;
    address public owner;

    /// @notice EMA half-life in seconds (launch: 5 minutes)
    uint256 public markHalfLife = 5 minutes;

    // --------------------------------------------
    //  Inventory / OI
    // --------------------------------------------

    uint256 public override inventorySize;
    uint256 public override shortOpenInterest;
    uint256 public longEscrowed;
    uint256 public override insuranceBuffer;
    mapping(address account => uint256 size) public accountShortSize;
    mapping(address account => uint256 size) public accountLongSize;

    // --------------------------------------------
    //  Marks / borrow index
    // --------------------------------------------

    uint256 public override markPrice;
    uint256 public markUpdatedAt;
    uint256 public borrowIndex;
    uint256 public borrowIndexUpdatedAt;

    BorrowCurve public curve;
    MarginParams public margins;

    // --------------------------------------------
    //  Positions
    // --------------------------------------------

    uint256 public override nextPositionId;
    mapping(uint256 positionId => Position position) internal _positions;
    mapping(address account => uint256[] ids) internal _positionsOf;

    // --------------------------------------------
    //  Modifiers
    // --------------------------------------------

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
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
        markSource = params.markSource;
        fundingController = params.fundingController;
        pbrTreasury = params.pbrTreasury;
        owner = params.owner;

        inventorySize = params.seededInventory;
        borrowIndex = WAD;
        borrowIndexUpdatedAt = block.timestamp;
        markUpdatedAt = block.timestamp;

        // r0=5%, slope1 → 25% at 80% util, slope2 → 150% at 100% util
        curve = BorrowCurve({ r0: 5e16, slope1: 25e16, slope2: 625e16, uKink: 8e17 });
        margins = MarginParams({
            initialMarginWad: 4e17,
            maintenanceMarginWad: 2e17,
            liquidationBountyWad: 5e16,
            insuranceSliceWad: 25e15,
            maxCloseImpactWad: 2e16,
            perAccountShortCapWad: 1e17
        });

        if (params.markSource != address(0)) {
            uint256 spot = IMarkSource(params.markSource).spotPriceWad();
            if (MarkMath.isSaneMark(spot)) {
                markPrice = spot;
                emit MarkUpdated(spot, spot, block.timestamp);
            }
        }

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
    function isLiquidatable(uint256 positionId) public view override returns (bool) {
        Position storage pos = _positions[positionId];
        if (!pos.open || pos.side != Side.SHORT) return false;
        if (markPrice == 0) return false;
        return MarginMath.belowMaintenance(pos.collateral, pos.saleProceeds, pos.size, markPrice, margins);
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
        _requireSlippageExactIn(bound);
        _requireMark();
        _accrueBorrowIndex();

        IERC20(collateral).safeTransferFrom(msg.sender, address(this), usdcIn);
        size = _swapExactIn(collateral, playerToken, usdcIn, bound);

        uint256 sizeBefore = accountLongSize[msg.sender];
        longEscrowed += size;
        accountLongSize[msg.sender] = sizeBefore + size;
        positionId = _openPosition(msg.sender, Side.LONG, LongOpenMode.USDC_IN, size, markPrice);
        _checkpointFunding(msg.sender, Side.LONG, sizeBefore, sizeBefore + size);

        emit LongOpened(positionId, msg.sender, size, markPrice, uint8(LongOpenMode.USDC_IN));
        _assertInvariants();
    }

    /// @inheritdoc IAdvancedTradeVault
    function openLongTokens(uint256 tokenAmount) external override nonReentrant returns (uint256 positionId) {
        if (tokenAmount == 0) revert ZeroAmount();
        _requireMark();
        _requireNotStaked(msg.sender);
        _accrueBorrowIndex();

        IERC20(playerToken).safeTransferFrom(msg.sender, address(this), tokenAmount);

        uint256 sizeBefore = accountLongSize[msg.sender];
        longEscrowed += tokenAmount;
        accountLongSize[msg.sender] = sizeBefore + tokenAmount;

        positionId = _openPosition(msg.sender, Side.LONG, LongOpenMode.TOKEN_DEPOSIT, tokenAmount, markPrice);
        _checkpointFunding(msg.sender, Side.LONG, sizeBefore, sizeBefore + tokenAmount);

        emit LongOpened(positionId, msg.sender, tokenAmount, markPrice, uint8(LongOpenMode.TOKEN_DEPOSIT));
        _assertInvariants();
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

        uint256 size = pos.size;
        uint256 sizeBefore = accountLongSize[msg.sender];
        uint256 sizeAfter = sizeBefore - size;
        accountLongSize[msg.sender] = sizeAfter;
        _checkpointFunding(msg.sender, Side.LONG, sizeBefore, sizeAfter);

        longEscrowed -= size;
        pos.open = false;
        pos.size = 0;

        if (mode == LongCloseMode.RETURN_TOKENS) {
            amountOut = size;
            IERC20(playerToken).safeTransfer(msg.sender, size);
        } else {
            _requireSlippageExactIn(bound);
            amountOut = _swapExactIn(playerToken, collateral, size, bound);
            IERC20(collateral).safeTransfer(msg.sender, amountOut);
        }

        emit PositionClosed(positionId, msg.sender, Side.LONG, 0);
        _assertInvariants();
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
        _requireSlippageExactIn(bound);
        _requireMark();
        _accrueBorrowIndex();

        if (size > idleInventory()) revert InsufficientInventory();
        if (shortOpenInterest + size > INVENTORY_HARD_CAP) revert InventoryHardCap();
        if (shortOpenInterest + size > inventorySize) revert InsufficientInventory();

        uint256 maxAccount = (inventorySize * margins.perAccountShortCapWad) / WAD;
        if (accountShortSize[msg.sender] + size > maxAccount) revert AccountShortCap();

        IERC20(collateral).safeTransferFrom(msg.sender, address(this), collateralIn);

        // Sell inventory into the pool (real sell pressure)
        saleProceeds = _swapExactIn(playerToken, collateral, size, bound);

        uint256 impact = _closeImpactWad(size);
        if (!MarginMath.meetsInitialMarginWithImpact(collateralIn, saleProceeds, size, markPrice, margins, impact)) {
            revert InsufficientMargin();
        }

        uint256 sizeBefore = accountShortSize[msg.sender];
        shortOpenInterest += size;
        accountShortSize[msg.sender] = sizeBefore + size;

        positionId = _openPosition(msg.sender, Side.SHORT, LongOpenMode.USDC_IN, size, markPrice);
        Position storage pos = _positions[positionId];
        pos.collateral = collateralIn;
        pos.saleProceeds = saleProceeds;
        pos.borrowIndexSnapshot = borrowIndex;

        _checkpointFunding(msg.sender, Side.SHORT, sizeBefore, sizeBefore + size);

        emit ShortOpened(positionId, msg.sender, size, collateralIn, saleProceeds, markPrice);
        _assertInvariants();
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
        _requireSlippageExactOut(bound);

        _accrueBorrowIndex();
        _accrueBorrowFee(positionId);

        uint256 size = pos.size;
        uint256 proceeds = pos.saleProceeds;
        uint256 col = pos.collateral;
        address account = pos.owner;

        uint256 sizeBefore = accountShortSize[account];
        uint256 sizeAfter = sizeBefore - size;
        accountShortSize[account] = sizeAfter;
        _checkpointFunding(account, Side.SHORT, sizeBefore, sizeAfter);

        uint256 buybackCost = _buybackShort(size, proceeds, col, bound);
        // accountShortSize already updated; _settleShortClose must not double-decrement
        pnl = _settleShortClose(positionId, account, size, proceeds, col, buybackCost, account, false);

        _assertInvariants();
    }

    // --------------------------------------------
    //  Fees / liquidations / marks
    // --------------------------------------------

    /// @inheritdoc IAdvancedTradeVault
    function accrueBorrowFee(uint256 positionId) external override nonReentrant returns (uint256 feeAmount) {
        Position storage pos = _positions[positionId];
        if (!pos.open || pos.side != Side.SHORT) revert PositionNotOpen();
        _accrueBorrowIndex();
        feeAmount = _accrueBorrowFee(positionId);
    }

    /// @inheritdoc IAdvancedTradeVault
    function liquidate(uint256 positionId, SlippageBound calldata bound) external override nonReentrant {
        _requireSlippageExactOut(bound);
        _accrueBorrowIndex();

        Position storage pos = _positions[positionId];
        if (!pos.open || pos.side != Side.SHORT) revert PositionNotOpen();

        _accrueBorrowFee(positionId);
        if (!isLiquidatable(positionId)) revert NotLiquidatable();

        uint256 size = pos.size;
        uint256 proceeds = pos.saleProceeds;
        uint256 col = pos.collateral;
        address account = pos.owner;
        uint256 notional_ = MarginMath.notional(size, markPrice);

        uint256 sizeBefore = accountShortSize[account];
        uint256 sizeAfter = sizeBefore - size;
        accountShortSize[account] = sizeAfter;
        _checkpointFunding(account, Side.SHORT, sizeBefore, sizeAfter);

        uint256 budget = proceeds + col + insuranceBuffer;
        uint256 amountInMax = bound.amountInMax;
        if (amountInMax > budget) amountInMax = budget;

        uint256 spent;
        uint256 bought;
        uint256 estCost = (MarginMath.buybackCost(size, markPrice) * 105) / 100;

        if (estCost <= amountInMax) {
            spent = _swapExactOut(collateral, playerToken, size, amountInMax, bound.deadline);
            bought = size;
        } else {
            // Bad debt path: spend full budget exact-in for whatever inventory can be restored
            if (budget == 0) {
                bought = 0;
                spent = 0;
            } else {
                SlippageBound memory inBound =
                    SlippageBound({ amountOutMin: 1, amountInMax: 0, deadline: bound.deadline });
                uint256 balBefore = IERC20(playerToken).balanceOf(address(this));
                uint256 usdcBefore = IERC20(collateral).balanceOf(address(this));
                _swapExactIn(collateral, playerToken, budget, inBound);
                bought = IERC20(playerToken).balanceOf(address(this)) - balBefore;
                spent = usdcBefore - IERC20(collateral).balanceOf(address(this));
            }
        }

        if (spent > proceeds + col) {
            uint256 insuranceUsed = spent - proceeds - col;
            if (insuranceUsed > insuranceBuffer) insuranceUsed = insuranceBuffer;
            insuranceBuffer -= insuranceUsed;
            col = 0;
            proceeds = 0;
        } else if (spent > proceeds) {
            col -= (spent - proceeds);
            proceeds = 0;
        } else {
            proceeds -= spent;
        }

        uint256 shortfall = size - bought;
        if (shortfall > 0) {
            inventorySize -= shortfall;
            emit InventoryWrittenOff(shortfall, inventorySize);
        }

        shortOpenInterest -= size;

        uint256 residual = col + proceeds;
        uint256 bounty = (notional_ * margins.liquidationBountyWad) / WAD;
        uint256 slice = (notional_ * margins.insuranceSliceWad) / WAD;
        if (bounty > residual) bounty = residual;
        residual -= bounty;
        if (slice > residual) slice = residual;
        residual -= slice;
        insuranceBuffer += slice;

        pos.open = false;
        pos.size = 0;
        pos.collateral = 0;
        pos.saleProceeds = 0;

        if (bounty > 0) IERC20(collateral).safeTransfer(msg.sender, bounty);
        if (residual > 0) IERC20(collateral).safeTransfer(account, residual);

        emit PositionLiquidated(positionId, account, msg.sender, bounty, slice);
        _assertInvariants();
    }

    /// @inheritdoc IAdvancedTradeVault
    function updateMark() external override returns (uint256 mark) {
        if (markSource == address(0)) revert ZeroAddress();
        uint256 spot = IMarkSource(markSource).spotPriceWad();
        if (!MarkMath.isSaneMark(spot)) revert MarkNotReady();

        uint256 dt = block.timestamp - markUpdatedAt;
        mark = MarkMath.emaUpdate(markPrice, spot, dt, markHalfLife);
        markPrice = mark;
        markUpdatedAt = block.timestamp;
        emit MarkUpdated(mark, spot, block.timestamp);
    }

    /// @inheritdoc IAdvancedTradeVault
    function claimFunding() external override nonReentrant returns (uint256 amount) {
        address fc = fundingController;
        if (fc == address(0)) revert ZeroAddress();
        amount = IFundingController(payable(fc)).claim(address(this), msg.sender);
        emit FundingClaimed(msg.sender, amount);
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
    function setSwapRouter(address swapRouter_) external override onlyOwner {
        address previous = swapRouter;
        swapRouter = swapRouter_;
        emit SwapRouterUpdated(previous, swapRouter_);
    }

    /// @inheritdoc IAdvancedTradeVault
    function setMarkSource(address markSource_) external override onlyOwner {
        address previous = markSource;
        markSource = markSource_;
        emit MarkSourceUpdated(previous, markSource_);
    }

    /// @inheritdoc IAdvancedTradeVault
    function setMarkHalfLife(uint256 halfLifeSeconds) external override onlyOwner {
        if (halfLifeSeconds == 0) revert ZeroAmount();
        markHalfLife = halfLifeSeconds;
        emit ParamsUpdated();
    }

    /// @inheritdoc IAdvancedTradeVault
    function setPlayerVault(address playerVault_) external override onlyOwner {
        address previous = playerVault;
        playerVault = playerVault_;
        emit PlayerVaultUpdated(previous, playerVault_);
    }

    /// @inheritdoc IAdvancedTradeVault
    function setImpactEstimator(address impactEstimator_) external override onlyOwner {
        address previous = impactEstimator;
        impactEstimator = impactEstimator_;
        emit ImpactEstimatorUpdated(previous, impactEstimator_);
    }

    /// @inheritdoc IAdvancedTradeVault
    function assertInvariants() external view override {
        _assertInvariants();
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _requireSlippageExactIn(SlippageBound calldata bound) internal view {
        if (bound.amountOutMin == 0) revert ZeroSlippageBound();
        if (bound.deadline == 0 || block.timestamp > bound.deadline) revert DeadlineExpired();
    }

    function _requireSlippageExactOut(SlippageBound calldata bound) internal view {
        if (bound.amountInMax == 0) revert ZeroSlippageBound();
        if (bound.deadline == 0 || block.timestamp > bound.deadline) revert DeadlineExpired();
    }

    function _requireMark() internal view {
        if (markPrice == 0) revert MarkNotReady();
    }

    function _requireNotStaked(address account) internal view {
        address pv = playerVault;
        if (pv == address(0)) return;
        if (IPlayerVault(pv).stakedBalance(account) > 0) revert StakedInPlayerVault();
    }

    function _closeImpactWad(uint256 size) internal view returns (uint256) {
        address est = impactEstimator;
        if (est == address(0)) return margins.maxCloseImpactWad;
        uint256 impact = IImpactEstimator(est).estimateCloseImpactWad(playerToken, size);
        return impact > margins.maxCloseImpactWad ? impact : margins.maxCloseImpactWad;
    }

    function _accrueBorrowIndex() internal {
        uint256 dt = block.timestamp - borrowIndexUpdatedAt;
        if (dt == 0) return;
        uint256 apr = BorrowMath.borrowApr(utilization(), curve);
        borrowIndex = BorrowMath.accrueIndex(borrowIndex, apr, dt);
        borrowIndexUpdatedAt = block.timestamp;
    }

    function _accrueBorrowFee(uint256 positionId) internal returns (uint256 feeAmount) {
        Position storage pos = _positions[positionId];
        if (!pos.open || pos.side != Side.SHORT) return 0;

        uint256 notional = MarginMath.notional(pos.size, markPrice == 0 ? pos.entryMark : markPrice);
        feeAmount = BorrowMath.feeOnNotional(notional, pos.borrowIndexSnapshot, borrowIndex);
        pos.borrowIndexSnapshot = borrowIndex;
        if (feeAmount == 0) return 0;

        if (feeAmount > pos.collateral) feeAmount = pos.collateral;
        pos.collateral -= feeAmount;

        uint256 toInsurance = feeAmount / 2;
        uint256 toTreasury = feeAmount - toInsurance;
        insuranceBuffer += toInsurance;
        if (toTreasury > 0) IERC20(collateral).safeTransfer(pbrTreasury, toTreasury);

        emit BorrowFeeAccrued(positionId, feeAmount, utilization());
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, SlippageBound memory bound)
        internal
        returns (uint256 amountOut)
    {
        address router = swapRouter;
        if (router == address(0)) revert SwapRouterNotSet();

        IERC20(tokenIn).forceApprove(router, amountIn);
        amountOut =
            IVaultSwapRouter(router).swapExactIn(tokenIn, tokenOut, amountIn, bound.amountOutMin, bound.deadline);
        IERC20(tokenIn).forceApprove(router, 0);

        if (amountOut < bound.amountOutMin) revert SlippageExceeded();
    }

    /// @dev Buy back exact `size` tokens; spends proceeds then collateral. Returns USDC spent.
    function _buybackShort(uint256 size, uint256 proceeds, uint256 col, SlippageBound calldata bound)
        internal
        returns (uint256 spent)
    {
        uint256 budget = proceeds + col;
        uint256 amountInMax = bound.amountInMax;
        if (amountInMax > budget) amountInMax = budget;
        if (amountInMax == 0) revert ZeroSlippageBound();

        spent = _swapExactOut(collateral, playerToken, size, amountInMax, bound.deadline);
        if (spent > budget) revert InsufficientMargin();
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 amountInMax, uint256 deadline)
        internal
        returns (uint256 amountIn)
    {
        address router = swapRouter;
        if (router == address(0)) revert SwapRouterNotSet();
        if (deadline == 0 || block.timestamp > deadline) revert DeadlineExpired();

        IERC20(tokenIn).forceApprove(router, amountInMax);
        amountIn = IVaultSwapRouter(router).swapExactOut(tokenIn, tokenOut, amountOut, amountInMax, deadline);
        IERC20(tokenIn).forceApprove(router, 0);

        if (amountIn > amountInMax) revert SlippageExceeded();
    }

    function _settleShortClose(
        uint256 positionId,
        address account,
        uint256 size,
        uint256 proceeds,
        uint256 col,
        uint256 buybackCost,
        address recipient,
        bool decrementAccount
    ) internal returns (int256 pnl) {
        shortOpenInterest -= size;
        if (decrementAccount) {
            accountShortSize[account] -= size;
        }

        Position storage pos = _positions[positionId];
        pos.open = false;
        pos.size = 0;
        pos.collateral = 0;
        pos.saleProceeds = 0;

        uint256 assets = proceeds + col;
        if (assets >= buybackCost) {
            uint256 surplus = assets - buybackCost;
            pnl = int256(surplus);
            if (surplus > 0) IERC20(collateral).safeTransfer(recipient, surplus);
        } else {
            pnl = -int256(buybackCost - assets);
        }

        emit PositionClosed(positionId, account, Side.SHORT, pnl);
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
            borrowIndexSnapshot: borrowIndex,
            openedAt: block.timestamp,
            open: true
        });
        _positionsOf[account].push(positionId);
    }

    function _assertInvariants() internal view {
        if (shortOpenInterest > inventorySize) revert InsufficientInventory();
        if (shortOpenInterest > INVENTORY_HARD_CAP) revert InventoryHardCap();

        uint256 tokenBal = IERC20(playerToken).balanceOf(address(this));
        // Idle inventory tokens remain; long escrow remains; sold shorts have left.
        // tokenBal == idleInventory + longEscrowed == inventorySize - shortOI + longEscrowed
        if (tokenBal != inventorySize - shortOpenInterest + longEscrowed) revert InsufficientInventory();
    }
}
