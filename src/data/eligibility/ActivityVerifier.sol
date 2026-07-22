// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { FunctionsWrapper } from "@base/abstract/FunctionsWrapper.sol";

struct SquadList {
    bytes32 contestantId;
    bytes32[] playerIds;
}

/**
 * @title ActivityVerifier
 * @notice Chainlink Functions consumer that stores squad activity lists per contestant.
 * @dev Request path: `verifyActivity` → `_sendRequestInlineJS` → DON → `_fulfillRequest`.
 *      Response ABI (encoded by the Functions source): `(bytes32 contestantId, bytes32[] playerIds)`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract ActivityVerifier is FunctionsWrapper {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 contestantId => SquadList) private _squadLists;
    mapping(bytes32 requestId => bool) private _pending;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    error UnexpectedRequestId(bytes32 requestId);

    event SquadListUpdated(bytes32 indexed contestantId, uint256 playerCount);
    event ActivityRequestFailed(bytes32 indexed requestId, bytes err);

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param router_ Functions router for this chain.
    /// @param subscriptionId_ Chainlink Functions subscription id.
    /// @param donId_ DON id for this chain / Functions version.
    /// @param fulfillGasLimit_ Callback gas limit for `_fulfillRequest`.
    constructor(
        address router_,
        uint64 subscriptionId_,
        bytes32 donId_,
        uint32 fulfillGasLimit_
    ) FunctionsWrapper(router_, subscriptionId_, donId_, fulfillGasLimit_) {}

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getSquadList(bytes32 contestantId)
        external
        view
        returns (bytes32 storedContestantId, bytes32[] memory playerIds)
    {
        SquadList storage list = _squadLists[contestantId];
        return (list.contestantId, list.playerIds);
    }

    // --------------------------------------------
    //  Requests
    // --------------------------------------------

    /// @notice Request a squad list via Chainlink Functions.
    /// @param source Inline JS; must return abi-encoded `(bytes32, bytes32[])`.
    /// @param args String args forwarded to the script (e.g. contestant / season ids).
    function verifyActivity(string calldata source, string[] calldata args) external returns (bytes32 requestId) {
        requestId = _sendRequestInlineJS(source, args);
        _pending[requestId] = true;
    }

    // --------------------------------------------
    //  Fulfillment
    // --------------------------------------------

    /// @inheritdoc FunctionsWrapper
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (!_pending[requestId]) revert UnexpectedRequestId(requestId);
        delete _pending[requestId];

        // Functions sets either `response` or `err`, never both.
        if (err.length > 0) {
            emit ActivityRequestFailed(requestId, err);
            return;
        }

        (bytes32 contestantId, bytes32[] memory playerIds) = abi.decode(response, (bytes32, bytes32[]));
        _squadLists[contestantId] = SquadList({ contestantId: contestantId, playerIds: playerIds });
        emit SquadListUpdated(contestantId, playerIds.length);
    }
}
