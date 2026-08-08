// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Minimal tournament registry stub for FeeRouter OOF even-split.
contract MockTournamentRegistry {
    address[] private _domesticHubs;

    function setDomesticPbrFeeHubs(address[] calldata hubs) external {
        delete _domesticHubs;
        for (uint256 i; i < hubs.length; ++i) {
            _domesticHubs.push(hubs[i]);
        }
    }

    function getAllDomesticPbrFeeHubs() external view returns (address[] memory hubs) {
        hubs = _domesticHubs;
    }
}
