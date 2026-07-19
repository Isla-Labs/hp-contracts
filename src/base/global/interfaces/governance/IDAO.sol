// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IDAO
 * @notice Minimal Aragon OSx DAO surface used by HP governance wiring.
 * @dev Full framework lives onchain on Base (`AragonBaseAddresses`). HP contracts treat the
 *      DAO address as root admin / beacon owner; plugins call `execute` on the DAO.
 *      See https://docs.aragon.org/osx-contracts/1.x/
 */
interface IDAO {
    struct Action {
        address to;
        uint256 value;
        bytes data;
    }

    /**
     * @notice Executes a list of actions on behalf of the DAO.
     * @param callId Identifier for the execution batch (plugin-defined).
     * @param actions Calls to perform as the DAO.
     * @param allowFailureMap Bitmap of actions allowed to fail without reverting the batch.
     * @return returnValues Return data per action.
     * @return failureMap Bitmap of which actions failed.
     */
    function execute(
        bytes32 callId,
        Action[] calldata actions,
        uint256 allowFailureMap
    ) external returns (bytes[] memory returnValues, uint256 failureMap);
}
