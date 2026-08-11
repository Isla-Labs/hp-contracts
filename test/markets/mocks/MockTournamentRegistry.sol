// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Minimal tournament registry stub for FeeRouter OOF / hub-registration checks.
contract MockTournamentRegistry {
    address[] private _domesticHubs;
    mapping(address => bool) private _isDomesticHub;

    function registerDomesticHub(address hub) external {
        if (hub == address(0) || _isDomesticHub[hub]) return;
        _isDomesticHub[hub] = true;
        _domesticHubs.push(hub);
    }

    function setDomesticPbrFeeHubs(address[] calldata hubs) external {
        uint256 existing = _domesticHubs.length;
        for (uint256 i; i < existing; ++i) {
            delete _isDomesticHub[_domesticHubs[i]];
        }
        delete _domesticHubs;

        for (uint256 i; i < hubs.length; ++i) {
            address hub = hubs[i];
            if (hub == address(0) || _isDomesticHub[hub]) continue;
            _isDomesticHub[hub] = true;
            _domesticHubs.push(hub);
        }
    }

    function getAllDomesticPbrFeeHubs() external view returns (address[] memory hubs) {
        hubs = _domesticHubs;
    }
}
