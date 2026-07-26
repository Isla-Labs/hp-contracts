// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library SethErrors {
    // --------------------------------------------
    //  AppRegistry
    // --------------------------------------------
    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error EmptyTvlContracts();
    error NotContract();
    error ContractAlreadyRegistered(address tvlContract);
    error ContractNotRegistered(address tvlContract);
    error NotRootDeployer();
    error EmptyBeneficiaries();
    error InvalidShareBps();
    error DuplicateBeneficiary(address account);
    error NotAppMinter();
    error InvalidAmount();
}
