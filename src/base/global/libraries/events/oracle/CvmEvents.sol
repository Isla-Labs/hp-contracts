// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CvmJob, CvmRouterConfig } from "@types/oracle/CvmTypes.sol";

library CvmEvents {
    // --------------------------------------------
    //  Router
    // --------------------------------------------

    event RequestStart(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed requestInitiator,
        CvmJob job,
        bytes args,
        uint32 callbackGasLimit,
        uint64 timeoutAt,
        address assignee,
        uint64 exclusiveUntil
    );

    event RequestProcessed(
        bytes32 indexed requestId,
        address indexed requester,
        address indexed transmitter,
        bool callbackSuccess,
        bytes response,
        bytes err,
        bytes callbackReturnData
    );

    event RequestCancelled(bytes32 indexed requestId, address indexed requester);

    event ConfigUpdated(CvmRouterConfig config);

    // --------------------------------------------
    //  Coordinator
    // --------------------------------------------

    event OracleRegistered(address indexed transmitter, bytes32 indexed deviceId);

    event OracleRegisteredWithAttestation(
        address indexed transmitter, bytes32 indexed deviceId, bytes32 indexed composeHash, uint64 expiresAt
    );

    event OracleRevoked(address indexed transmitter, bytes32 indexed deviceId);

    event ComposeHashAdded(bytes32 indexed composeHash);

    event ComposeHashRemoved(bytes32 indexed composeHash);

    event AttestationVerifierSet(address indexed verifier);

    event RegistrationTtlSet(uint64 ttl);

    event AttestationComposeAllowed(bytes32 indexed composeHash, bool allowed);
}
