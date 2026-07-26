// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

interface IPBRScoreOracle {
    function runningM(bytes32 appId) external view returns (uint256);

    function runningS(bytes32 appId) external view returns (uint256);

    function getScores(bytes32 appId) external view returns (uint256 m, uint256 s, uint64 updatedAt);
}
