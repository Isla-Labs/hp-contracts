// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IPbrFeeHub
 * @notice Cross-contract surface for per-domestic-league fee splitters.
 */
interface IPbrFeeHub {
    function leagueId() external view returns (bytes32);

    function leagueTreasury() external view returns (address);

    function setDomesticCups(address[] calldata cups_) external;

    function setContinental(address[] calldata treasuries_) external;

    function setInternational(address[] calldata treasuries_) external;

    function getDomesticCups() external view returns (address[] memory);

    function getContinental() external view returns (address[] memory);

    function getInternational() external view returns (address[] memory);
}
