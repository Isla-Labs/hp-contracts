// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { FunctionsClient } from "@chainlink/functions/v1_3_0/FunctionsClient.sol";
import { FunctionsRequest } from "@chainlink/functions/v1_0_0/libraries/FunctionsRequest.sol";

/**
 * @title DataProvider
 * @notice Abstract Chainlink Functions client for fetching offchain data.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract DataProvider is FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    /// @notice Last request id returned by the router (monitoring / correlation)
    bytes32 public lastRequestId;

    /// @notice Subscription billed for consumer requests
    uint64 public subscriptionId;

    /// @notice Gas reserved for `handleOracleFulfillment` in the consumer
    uint32 public fulfillGasLimit;

    /// @notice DON id for this chain and Functions version
    bytes32 public donId;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    /// @notice Thrown when the Oracle is not configured
    error OracleNotConfigured();

    /// @notice Thrown when the JavaScript source is empty
    error EmptySource();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param router Functions router address for this chain (not an `AddressProvider` address)
    /// @param subscriptionId_ Chainlink Functions subscription id
    /// @param donId_ DON id (see Chainlink docs for your network)
    /// @param fulfillGasLimit_ Callback gas limit for fulfillments
    constructor(
        address router,
        uint64 subscriptionId_,
        bytes32 donId_,
        uint32 fulfillGasLimit_
    ) FunctionsClient(router) {
        subscriptionId = subscriptionId_;
        donId = donId_;
        fulfillGasLimit = fulfillGasLimit_;
    }

    // --------------------------------------------
    //  Admin (Optional: child can override)
    // --------------------------------------------

    function _setSubscriptionId(uint64 subscriptionId_) internal {
        subscriptionId = subscriptionId_;
    }

    function _setDonId(bytes32 donId_) internal {
        donId = donId_;
    }

    function _setFulfillGasLimit(uint32 fulfillGasLimit_) internal {
        fulfillGasLimit = fulfillGasLimit_;
    }

    // --------------------------------------------
    //  Inline JavaScript → request
    // --------------------------------------------

    /// @notice Run inline JS with no args (`args` / `bytesArgs` in the request stay empty).
    function _sendRequestInlineJS(string memory javaScriptSource) internal returns (bytes32 requestId) {
        if (bytes(javaScriptSource).length == 0) revert EmptySource();
        _requireOracleConfig();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(javaScriptSource);
        return _storeLast(_sendRequest(req.encodeCBOR(), subscriptionId, fulfillGasLimit, donId));
    }

    /// @notice Run inline JS with string args (available in the script as `args`).
    function _sendRequestInlineJS(
        string memory javaScriptSource,
        string[] memory args
    ) internal returns (bytes32 requestId) {
        if (bytes(javaScriptSource).length == 0) revert EmptySource();
        _requireOracleConfig();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(javaScriptSource);
        if (args.length > 0) {
            req.setArgs(args);
        }

        return _storeLast(_sendRequest(req.encodeCBOR(), subscriptionId, fulfillGasLimit, donId));
    }

    /// @notice Run inline JS with string args, bytes args, and optional remote encrypted secrets reference.
    /// @param encryptedSecretsReference Encrypted secrets blob for `addSecretsReference`; pass empty to omit secrets.
    function _sendRequestInlineJS(
        string memory javaScriptSource,
        string[] memory args,
        bytes[] memory bytesArgs,
        bytes memory encryptedSecretsReference
    ) internal returns (bytes32 requestId) {
        if (bytes(javaScriptSource).length == 0) revert EmptySource();
        _requireOracleConfig();

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(javaScriptSource);
        if (args.length > 0) {
            req.setArgs(args);
        }
        if (bytesArgs.length > 0) {
            req.setBytesArgs(bytesArgs);
        }
        if (encryptedSecretsReference.length > 0) {
            req.addSecretsReference(encryptedSecretsReference);
        }

        return _storeLast(_sendRequest(req.encodeCBOR(), subscriptionId, fulfillGasLimit, donId));
    }

    /// @notice Send a fully custom request (e.g. after `addDONHostedSecrets` on `req` in the child).
    function _sendRequestPrepared(FunctionsRequest.Request memory req) internal returns (bytes32 requestId) {
        _requireOracleConfig();
        return _storeLast(_sendRequest(req.encodeCBOR(), subscriptionId, fulfillGasLimit, donId));
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _requireOracleConfig() internal view {
        if (subscriptionId == 0 || donId == bytes32(0) || fulfillGasLimit == 0) revert OracleNotConfigured();
    }

    function _storeLast(bytes32 requestId) private returns (bytes32) {
        lastRequestId = requestId;
        return requestId;
    }

    /// @inheritdoc FunctionsClient
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal virtual override;
}
