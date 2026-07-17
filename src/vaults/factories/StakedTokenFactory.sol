// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { VaultsErrors as Errors } from "@base/global/libraries/errors/VaultsErrors.sol";
import { VaultsEvents as Events } from "@base/global/libraries/events/VaultsEvents.sol";
import { StakedToken } from "@vaults/StakedToken.sol";

/**
 * @title StakedTokenFactory
 * @notice Thin helper to deploy a vault-bound `StakedToken`.
 * @dev Prefer `PlayerVaultFactory.create`, which wires vault + stToken atomically.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract StakedTokenFactory {
    function create(string calldata name, string calldata symbol, address vault)
        external
        returns (address stToken)
    {
        if (vault == address(0)) revert Errors.ZeroAddress();
        stToken = address(new StakedToken(name, symbol, vault));
        emit Events.StakedTokenCreated(vault, stToken, name, symbol);
    }
}
