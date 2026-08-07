// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

interface IStakeVesting {
    function allocate(address token) external;

    function setBeneficiaries(address[] calldata accounts, uint256[] calldata sharesWad) external;

    function releaseAdvancedTrade(address token, address to, uint256 amount) external;

    function unlock(address token) external;

    function distributeUnlocked(address token) external;

    function unlockAndDistribute(address token) external;

    function claimPbr(address token) external returns (uint256 payout);
}
