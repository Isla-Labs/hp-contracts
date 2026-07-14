// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { IFundingController } from "./interfaces/IFundingController.sol";
import { ILiquiditySource } from "./interfaces/ILiquiditySource.sol";
import { GapMath } from "./libraries/GapMath.sol";
import { MarkMath } from "./libraries/MarkMath.sol";

/**
 * @title FundingController
 * @notice Phase 2: FRT custody, drip budget, share-identity FMV gaps, Synthetix-style side indices.
 * @dev Accrual is time-weighted and size-additive. Pause stops accrual only — vault Phase 1 ops continue.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FundingController is IFundingController, Ownable2Step, ReentrancyGuard {
    uint256 internal constant PRECISION = 1e18;

    // --------------------------------------------
    //  Global
    // --------------------------------------------

    bool public override isPaused;
    uint256 public dripPerSecond;
    uint256 public dripUpdatedAt;
    uint256 public override totalPpm; // Σ ppm
    uint256 public override totalLiq; // Σ liq (post-grace)
    uint256 public totalScore; // Σ |g|

    address public liquiditySource;

    uint256 public gMaxWad = 5e17; // ±0.5
    uint256 public gDeadWad = 2e16; // ±0.02
    uint256 public rateCapBps = 500; // 5% of B per market
    uint256 public liqHalfLife = 30 minutes;

    // --------------------------------------------
    //  Per-market
    // --------------------------------------------

    struct Market {
        address playerToken;
        bool registered;
        bool inGrace;
        uint256 ppm;
        uint256 liq;
        int256 gapWad;
        uint256 marketRate; // wei/sec allocated to this market
        uint256 rateLong; // wei/sec accruing to long side (0 if offside)
        uint256 rateShort;
        uint256 rptLong;
        uint256 rptShort;
        uint256 totalLong;
        uint256 totalShort;
        uint256 lastUpdate;
        uint256 liqUpdatedAt;
        uint256 score;
    }

    mapping(address vault => Market market) internal _markets;
    mapping(address vault => bool paused) internal _marketPaused;

    mapping(address vault => mapping(address user => uint256 accrued)) internal _accrued;
    mapping(address vault => mapping(address user => mapping(bool isLong => uint256 checkpoint))) internal _userCheckpoint;
    mapping(address vault => mapping(address user => mapping(bool isLong => uint256 size))) internal _userSize;

    // --------------------------------------------
    //  Init
    // --------------------------------------------

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

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
        return _markets[vault].gapWad;
    }

    /// @inheritdoc IFundingController
    function marketRate(address vault) external view override returns (uint256) {
        return _markets[vault].marketRate;
    }

    /// @inheritdoc IFundingController
    function rewardPerToken(address vault, bool isLong) external view override returns (uint256) {
        Market storage m = _markets[vault];
        return isLong ? m.rptLong : m.rptShort;
    }

    /// @inheritdoc IFundingController
    function pendingFunding(address vault, address user) public view override returns (uint256) {
        Market storage m = _markets[vault];
        if (!m.registered) return 0;

        (uint256 rptLong, uint256 rptShort) = _previewRpt(m);
        uint256 accrued = _accrued[vault][user];
        accrued += _pendingSide(vault, user, true, rptLong);
        accrued += _pendingSide(vault, user, false, rptShort);
        return accrued;
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
        Market storage m = _markets[vault];
        m.playerToken = playerToken;
        m.registered = true;
        m.inGrace = true; // excluded from aggregates until grace cleared
        m.lastUpdate = block.timestamp;
        emit MarketRegistered(vault, playerToken);
        emit GraceUpdated(vault, true);
    }

    /// @inheritdoc IFundingController
    function checkpoint(address vault, address user, bool isLong, uint256 sizeBefore, uint256 sizeAfter)
        external
        override
    {
        Market storage m = _markets[vault];
        if (!m.registered) revert MarketNotRegistered();
        if (msg.sender != vault) revert NotVault();

        _settleMarket(m);
        _settleUser(vault, user, isLong, m);

        if (isLong) {
            m.totalLong = m.totalLong - sizeBefore + sizeAfter;
        } else {
            m.totalShort = m.totalShort - sizeBefore + sizeAfter;
        }
        _userSize[vault][user][isLong] = sizeAfter;

        // Refresh checkpoint to current rpt after size change
        _userCheckpoint[vault][user][isLong] = isLong ? m.rptLong : m.rptShort;
    }

    /// @inheritdoc IFundingController
    function claim(address vault, address user) external override nonReentrant returns (uint256 amount) {
        Market storage m = _markets[vault];
        if (!m.registered) revert MarketNotRegistered();
        if (isPaused || _marketPaused[vault]) revert FundingPaused();

        _settleMarket(m);
        _settleUser(vault, user, true, m);
        _settleUser(vault, user, false, m);

        amount = _accrued[vault][user];
        if (amount == 0) return 0;
        if (amount > address(this).balance) amount = address(this).balance;

        _accrued[vault][user] = 0;
        (bool ok,) = user.call{ value: amount }("");
        if (!ok) revert TransferFailed();

        emit FundingClaimed(vault, user, amount);
    }

    // --------------------------------------------
    //  Remarque
    // --------------------------------------------

    /// @inheritdoc IFundingController
    function remarque(address vault) external override {
        Market storage m = _markets[vault];
        if (!m.registered) revert MarketNotRegistered();

        _settleMarket(m);
        _refreshLiq(m);
        _recomputeGapAndRates(vault, m);

        emit Remarque(vault, m.gapWad, m.marketRate, block.timestamp);
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
        if (!_markets[vault].registered) revert MarketNotRegistered();
        _marketPaused[vault] = paused;
        emit MarketPaused(vault, paused);
    }

    /// @inheritdoc IFundingController
    function resetDrip(uint256 runwaySeconds) external override onlyOwner {
        if (runwaySeconds == 0) revert InvalidParam();
        uint256 bal = address(this).balance;
        dripPerSecond = bal / runwaySeconds;
        dripUpdatedAt = block.timestamp;
        emit DripReset(dripPerSecond, runwaySeconds, block.timestamp);
    }

    /// @inheritdoc IFundingController
    function setPpm(address vault, uint256 ppm) external override onlyOwner {
        Market storage m = _markets[vault];
        if (!m.registered) revert MarketNotRegistered();

        if (!m.inGrace) {
            totalPpm = totalPpm - m.ppm + ppm;
        }
        m.ppm = ppm;
        emit PpmUpdated(vault, ppm, totalPpm);
    }

    /// @inheritdoc IFundingController
    function setLiq(address vault, uint256 liq) external override onlyOwner {
        Market storage m = _markets[vault];
        if (!m.registered) revert MarketNotRegistered();
        _setLiq(m, liq);
        m.liqUpdatedAt = block.timestamp;
    }

    /// @inheritdoc IFundingController
    function setGrace(address vault, bool inGrace) external override onlyOwner {
        Market storage m = _markets[vault];
        if (!m.registered) revert MarketNotRegistered();
        if (m.inGrace == inGrace) {
            emit GraceUpdated(vault, inGrace);
            return;
        }

        if (inGrace) {
            // leaving aggregates
            totalPpm -= m.ppm;
            totalLiq -= m.liq;
            totalScore -= m.score;
            m.score = 0;
            m.marketRate = 0;
            m.rateLong = 0;
            m.rateShort = 0;
        } else {
            totalPpm += m.ppm;
            totalLiq += m.liq;
        }
        m.inGrace = inGrace;
        emit GraceUpdated(vault, inGrace);
    }

    /// @inheritdoc IFundingController
    function setLiquiditySource(address source) external override onlyOwner {
        liquiditySource = source;
        emit ParamsUpdated();
    }

    /// @inheritdoc IFundingController
    function setFundingParams(uint256 gMaxWad_, uint256 gDeadWad_, uint256 rateCapBps_, uint256 liqHalfLife_)
        external
        override
        onlyOwner
    {
        gMaxWad = gMaxWad_;
        gDeadWad = gDeadWad_;
        rateCapBps = rateCapBps_;
        liqHalfLife = liqHalfLife_;
        emit ParamsUpdated();
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _settleMarket(Market storage m) internal {
        if (isPaused) {
            m.lastUpdate = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - m.lastUpdate;
        if (dt == 0) return;

        if (m.rateLong > 0 && m.totalLong > 0) {
            m.rptLong += (m.rateLong * dt * PRECISION) / m.totalLong;
        }
        if (m.rateShort > 0 && m.totalShort > 0) {
            m.rptShort += (m.rateShort * dt * PRECISION) / m.totalShort;
        }
        m.lastUpdate = block.timestamp;
    }

    function _settleUser(address vault, address user, bool isLong, Market storage m) internal {
        uint256 size = _userSize[vault][user][isLong];
        if (size == 0) {
            _userCheckpoint[vault][user][isLong] = isLong ? m.rptLong : m.rptShort;
            return;
        }
        uint256 rpt = isLong ? m.rptLong : m.rptShort;
        uint256 cp = _userCheckpoint[vault][user][isLong];
        if (rpt > cp) {
            _accrued[vault][user] += (size * (rpt - cp)) / PRECISION;
        }
        _userCheckpoint[vault][user][isLong] = rpt;
    }

    function _pendingSide(address vault, address user, bool isLong, uint256 rpt)
        internal
        view
        returns (uint256)
    {
        uint256 size = _userSize[vault][user][isLong];
        if (size == 0) return 0;
        uint256 cp = _userCheckpoint[vault][user][isLong];
        if (rpt <= cp) return 0;
        return (size * (rpt - cp)) / PRECISION;
    }

    function _previewRpt(Market storage m) internal view returns (uint256 rptLong, uint256 rptShort) {
        rptLong = m.rptLong;
        rptShort = m.rptShort;
        if (isPaused) return (rptLong, rptShort);
        uint256 dt = block.timestamp - m.lastUpdate;
        if (dt == 0) return (rptLong, rptShort);
        if (m.rateLong > 0 && m.totalLong > 0) {
            rptLong += (m.rateLong * dt * PRECISION) / m.totalLong;
        }
        if (m.rateShort > 0 && m.totalShort > 0) {
            rptShort += (m.rateShort * dt * PRECISION) / m.totalShort;
        }
    }

    function _refreshLiq(Market storage m) internal {
        address src = liquiditySource;
        if (src == address(0)) return;
        uint256 spotLiq = ILiquiditySource(src).liquidityUsd(m.playerToken);

        if (m.liq == 0) {
            _setLiq(m, spotLiq);
            m.liqUpdatedAt = block.timestamp;
            return;
        }

        uint256 dt = block.timestamp - m.liqUpdatedAt;
        if (dt == 0) dt = 1;
        uint256 halfLife = liqHalfLife == 0 ? 1 : liqHalfLife;
        uint256 newLiq = MarkMath.emaUpdate(m.liq, spotLiq, dt, halfLife);
        _setLiq(m, newLiq);
        m.liqUpdatedAt = block.timestamp;
    }

    function _setLiq(Market storage m, uint256 newLiq) internal {
        if (!m.inGrace) {
            totalLiq = totalLiq - m.liq + newLiq;
        }
        m.liq = newLiq;
    }

    function _recomputeGapAndRates(address, /* vault */ Market storage m) internal {
        // Remove old score from global
        if (!m.inGrace) {
            totalScore -= m.score;
        }

        if (m.inGrace || isPaused) {
            m.gapWad = 0;
            m.score = 0;
            m.marketRate = 0;
            m.rateLong = 0;
            m.rateShort = 0;
            return;
        }

        int256 g = GapMath.clamp(GapMath.computeGap(m.ppm, totalPpm, m.liq, totalLiq), gMaxWad);
        m.gapWad = g;
        uint256 s = GapMath.score(g, gDeadWad);
        m.score = s;
        totalScore += s;

        uint256 B = dripPerSecond;
        uint256 rate;
        if (s > 0 && totalScore > 0 && B > 0) {
            rate = (B * s) / totalScore;
            uint256 cap = (B * rateCapBps) / 10_000;
            if (rate > cap) rate = cap;
        }
        m.marketRate = rate;

        uint256 a = GapMath.abs(g);
        if (a <= gDeadWad || rate == 0) {
            m.rateLong = 0;
            m.rateShort = 0;
        } else if (g > 0) {
            // undervalued → longs corrective
            m.rateLong = rate;
            m.rateShort = 0;
        } else {
            m.rateLong = 0;
            m.rateShort = rate;
        }
    }
}
