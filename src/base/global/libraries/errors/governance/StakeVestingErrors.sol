// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library StakeVestingErrors {
    error ZeroAddress();
    error ZeroAmount();
    error NotConfigured();
    error VaultMissing(bytes32 playerId);
    error LengthMismatch(uint256 left, uint256 right);
    error TransferFailed();
    error EmptyBeneficiaries();
    error InvalidBeneficiaryShares();
    error NothingToUnlock();
    error InsufficientExcessReserve();
}
