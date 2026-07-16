// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

/**
 * @title PbrFeeHub
 * @notice Per-league fee splitter: `FeeRouter` → hub → per-cup `PbrTreasury` destinations.
 * @dev Bound to a single `leagueId`. No matchweek / claim logic. On receive, ETH is split
 *      by BPS across configured child treasuries. Failed legs are tracked in `pending`
 *      and retried via `forward`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHub is Initializable, AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;

    bytes32 public leagueId;

    address[] private _treasuries;
    mapping(address treasury => uint16) public treasuryBps;
    mapping(address treasury => uint256) public pending;

    event FeesReceived(uint256 amount);
    event FeesRelayed(address indexed treasury, uint256 amount);
    event FeesQueued(address indexed treasury, uint256 amount);
    event SplitUpdated(address[] treasuries, uint16[] bps);

    error ZeroAddress();
    error ZeroId();
    error LengthMismatch();
    error EmptySplit();
    error InvalidBpsTotal(uint256 total);
    error DuplicateTreasury(address treasury);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, bytes32 leagueId_, address[] calldata treasuries_, uint16[] calldata bps_)
        external
        initializer
    {
        if (admin_ == address(0)) revert ZeroAddress();
        if (leagueId_ == bytes32(0)) revert ZeroId();

        leagueId = leagueId_;
        _grantRole(ADMIN_ROLE, admin_);
        _setSplit(treasuries_, bps_);
    }

    receive() external payable nonReentrant {
        _split(msg.value);
    }

    /// @notice Retries any pending failed relay amounts
    function forward() external nonReentrant {
        uint256 length = _treasuries.length;
        for (uint256 i; i < length; ++i) {
            address treasury = _treasuries[i];
            uint256 amount = pending[treasury];
            if (amount == 0) continue;

            pending[treasury] = 0;
            (bool ok,) = treasury.call{ value: amount }("");
            if (ok) {
                emit FeesRelayed(treasury, amount);
            } else {
                pending[treasury] = amount;
                emit FeesQueued(treasury, amount);
            }
        }
    }

    function setSplit(address[] calldata treasuries_, uint16[] calldata bps_) external onlyRole(ADMIN_ROLE) {
        _setSplit(treasuries_, bps_);
    }

    function getTreasuries() external view returns (address[] memory) {
        return _treasuries;
    }

    function _split(uint256 amount) internal {
        if (amount == 0) return;

        uint256 length = _treasuries.length;
        if (length == 0) {
            emit FeesQueued(address(0), amount);
            return;
        }

        emit FeesReceived(amount);

        uint256 distributed;
        for (uint256 i; i < length; ++i) {
            address treasury = _treasuries[i];
            uint256 share = i == length - 1 ? amount - distributed : (amount * treasuryBps[treasury]) / BPS_DENOMINATOR;
            if (share == 0) continue;
            distributed += share;

            (bool ok,) = treasury.call{ value: share }("");
            if (ok) {
                emit FeesRelayed(treasury, share);
            } else {
                pending[treasury] += share;
                emit FeesQueued(treasury, share);
            }
        }
    }

    function _setSplit(address[] calldata treasuries_, uint16[] calldata bps_) internal {
        uint256 length = treasuries_.length;
        if (length == 0) revert EmptySplit();
        if (length != bps_.length) revert LengthMismatch();

        uint256 prev = _treasuries.length;
        for (uint256 i; i < prev; ++i) {
            delete treasuryBps[_treasuries[i]];
        }
        delete _treasuries;

        uint256 totalBps;
        for (uint256 i; i < length; ++i) {
            address treasury = treasuries_[i];
            if (treasury == address(0)) revert ZeroAddress();
            if (treasuryBps[treasury] != 0) revert DuplicateTreasury(treasury);

            uint16 bps = bps_[i];
            if (bps == 0) revert EmptySplit();

            treasuryBps[treasury] = bps;
            _treasuries.push(treasury);
            totalBps += bps;
        }

        if (totalBps != BPS_DENOMINATOR) revert InvalidBpsTotal(totalBps);
        emit SplitUpdated(treasuries_, bps_);
    }
}
