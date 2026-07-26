// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

interface IPBRTreasury {
    function claim(bytes32 appId, uint64 epochId, address beneficiary) external returns (uint256 payout);

    function previewClaim(
        bytes32 appId,
        uint64 epochId,
        address beneficiary
    ) external view returns (uint256 payout);
}
