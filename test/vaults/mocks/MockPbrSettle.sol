// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

contract MockPbrSettle {
    bytes32 public lastUtilizedHash;
    uint256 public startCount;

    function startRound(bytes32, uint16, uint32, bytes32 utilizedHash)
        external
        returns (bytes32[] memory requestIds)
    {
        lastUtilizedHash = utilizedHash;
        unchecked {
            ++startCount;
        }
        requestIds = new bytes32[](1);
        requestIds[0] = keccak256(abi.encode(utilizedHash, startCount));
    }
}
