// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Treasury stub for PbrSettle.applyFixtureSettlement.
contract MockPbrTreasury {
    bool public nextDone;
    uint256 public applyCount;

    bytes32 public lastFixtureId;
    bytes32 public lastFixtureDigest;
    address[] internal _lastVaults;
    uint256[] internal _lastMwPoints;

    function setNextDone(bool done) external {
        nextDone = done;
    }

    function applyFixtureSettlement(
        bytes32 fixtureId_,
        bytes32 fixtureDigest_,
        address[] calldata vaults_,
        uint256[] calldata mwPoints_
    ) external returns (bool done_) {
        lastFixtureId = fixtureId_;
        lastFixtureDigest = fixtureDigest_;
        delete _lastVaults;
        delete _lastMwPoints;
        for (uint256 i; i < vaults_.length; ++i) {
            _lastVaults.push(vaults_[i]);
            _lastMwPoints.push(mwPoints_[i]);
        }
        unchecked {
            ++applyCount;
        }
        return nextDone;
    }

    function lastVaults() external view returns (address[] memory) {
        return _lastVaults;
    }

    function lastMwPoints() external view returns (uint256[] memory) {
        return _lastMwPoints;
    }
}
