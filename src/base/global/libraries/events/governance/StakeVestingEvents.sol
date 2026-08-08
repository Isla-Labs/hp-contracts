// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library StakeVestingEvents {
    event ExcessAllocated(
        address indexed token, bytes32 indexed playerId, uint256 advancedTradeAmount, uint256 vaultAmount
    );
    event ExcessTrancheUnlocked(address indexed token, uint8 tranche, uint256 amount);
    event ExcessVestedDistributed(address indexed token, uint256 amount);
    event ExcessPbrDistributed(address indexed token, uint256 amount);
    event ExcessBeneficiariesUpdated(uint256 beneficiaryCount);
    event AdvancedTradeReleased(address indexed token, address indexed to, uint256 amount);
    event ExcessTokenRescued(address indexed token, address indexed to, uint256 amount);
}
