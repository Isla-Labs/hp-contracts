// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Mock treasury factory returning deterministic addresses via CREATE.
contract MockPbrTreasuryFactory {
    uint256 public createCount;

    function create(bytes32, uint16, bytes32) external returns (address) {
        unchecked {
            ++createCount;
        }
        return address(new MockTreasurySink());
    }
}

contract MockPbrFeeHubFactory {
    uint256 public createCount;

    function create(bytes32, address) external returns (address) {
        unchecked {
            ++createCount;
        }
        return address(new MockPbrFeeHub());
    }
}

contract MockTreasurySink {
    receive() external payable { }
}

contract MockPbrFeeHub {
    address[] private _cups;
    address[] private _continental;
    address[] private _international;

    function getDomesticCups() external view returns (address[] memory) {
        return _cups;
    }

    function getContinental() external view returns (address[] memory) {
        return _continental;
    }

    function getInternational() external view returns (address[] memory) {
        return _international;
    }

    function setDomesticCups(address[] calldata cups_) external {
        delete _cups;
        for (uint256 i; i < cups_.length; ++i) {
            _cups.push(cups_[i]);
        }
    }

    function setContinental(address[] calldata treasuries_) external {
        delete _continental;
        for (uint256 i; i < treasuries_.length; ++i) {
            _continental.push(treasuries_[i]);
        }
    }

    function setInternational(address[] calldata treasuries_) external {
        delete _international;
        for (uint256 i; i < treasuries_.length; ++i) {
            _international.push(treasuries_[i]);
        }
    }
}
