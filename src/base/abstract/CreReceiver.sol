// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ERC165 } from "@openzeppelin/utils/introspection/ERC165.sol";
import { IERC165 } from "@openzeppelin/utils/introspection/IERC165.sol";

import { ICreReceiver } from "@base/global/interfaces/data/ICreReceiver.sol";

/**
 * @title CreReceiver
 * @notice Abstract CRE / Keystone report consumer — counterpart to the old Functions `Oracle`.
 * @dev Functions `Oracle` *pulled* data via `_sendRequest` → `_fulfillRequest`.
 *      CRE *pushes* signed reports: KeystoneForwarder → `onReport` → `_processReport`.
 *
 *      Children implement `_processReport` with domain logic (e.g. decode schedule digests
 *      and call `FixtureCommitment.commit(DigestSource.CRE, …)`).
 *
 *      Config mirrors Chainlink's `ReceiverTemplate`: required forwarder, optional workflow
 *      id / owner / name checks. Admin setters are `internal` so children can gate them with
 *      AccessControl / Ownable as they prefer (same pattern as `Oracle`'s `_setSubscriptionId`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 * @custom:see https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts
 */
abstract contract CreReceiver is ICreReceiver, ERC165 {
    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    /// @notice Keystone forwarder allowed to call `onReport` (`address(0)` disables the check — insecure).
    address private _forwarder;

    /// @notice If non-zero, only reports from this workflow owner are accepted.
    address private _expectedAuthor;

    /// @notice If non-zero, only this workflow name is accepted (requires `_expectedAuthor`).
    bytes10 private _expectedWorkflowName;

    /// @notice If non-zero, only this workflow id is accepted.
    bytes32 private _expectedWorkflowId;

    /// @notice Last accepted workflow id (monitoring / correlation; analogous to `Oracle.lastRequestId`).
    bytes32 public lastWorkflowId;

    /// @notice Last accepted workflow owner.
    address public lastWorkflowOwner;

    /// @notice Last accepted reportId (trailing 2 bytes of production metadata; zero if absent).
    bytes2 public lastReportId;

    // Hex lookup for workflow-name hashing (Chainlink ReceiverTemplate convention).
    bytes private constant HEX_CHARS = "0123456789abcdef";

    // --------------------------------------------
    //  Errors & Events
    // --------------------------------------------

    error InvalidForwarderAddress();
    error InvalidSender(address sender, address expected);
    error InvalidAuthor(address received, address expected);
    error InvalidWorkflowName(bytes10 received, bytes10 expected);
    error InvalidWorkflowId(bytes32 received, bytes32 expected);
    error WorkflowNameRequiresAuthorValidation();
    error InvalidMetadataLength(uint256 length);

    event ForwarderAddressUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedAuthorUpdated(address indexed previousAuthor, address indexed newAuthor);
    event ExpectedWorkflowNameUpdated(bytes10 indexed previousName, bytes10 indexed newName);
    event ExpectedWorkflowIdUpdated(bytes32 indexed previousId, bytes32 indexed newId);
    event SecurityWarning(string message);
    event ReportReceived(bytes32 indexed workflowId, address indexed workflowOwner, bytes2 reportId);

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param forwarder_ Chainlink `KeystoneForwarder` for this chain (required; non-zero).
    constructor(address forwarder_) {
        if (forwarder_ == address(0)) revert InvalidForwarderAddress();
        _forwarder = forwarder_;
        emit ForwarderAddressUpdated(address(0), forwarder_);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getForwarderAddress() external view returns (address) {
        return _forwarder;
    }

    function getExpectedAuthor() external view returns (address) {
        return _expectedAuthor;
    }

    function getExpectedWorkflowName() external view returns (bytes10) {
        return _expectedWorkflowName;
    }

    function getExpectedWorkflowId() external view returns (bytes32) {
        return _expectedWorkflowId;
    }

    // --------------------------------------------
    //  ICreReceiver
    // --------------------------------------------

    /// @inheritdoc ICreReceiver
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        if (_forwarder != address(0) && msg.sender != _forwarder) {
            revert InvalidSender(msg.sender, _forwarder);
        }

        (bytes32 workflowId, bytes10 workflowName, address workflowOwner, bytes2 reportId) = _decodeMetadata(metadata);

        if (_expectedWorkflowId != bytes32(0) || _expectedAuthor != address(0) || _expectedWorkflowName != bytes10(0)) {
            if (_expectedWorkflowId != bytes32(0) && workflowId != _expectedWorkflowId) {
                revert InvalidWorkflowId(workflowId, _expectedWorkflowId);
            }
            if (_expectedAuthor != address(0) && workflowOwner != _expectedAuthor) {
                revert InvalidAuthor(workflowOwner, _expectedAuthor);
            }
            if (_expectedWorkflowName != bytes10(0)) {
                if (_expectedAuthor == address(0)) revert WorkflowNameRequiresAuthorValidation();
                if (workflowName != _expectedWorkflowName) {
                    revert InvalidWorkflowName(workflowName, _expectedWorkflowName);
                }
            }
        }

        lastWorkflowId = workflowId;
        lastWorkflowOwner = workflowOwner;
        lastReportId = reportId;
        emit ReportReceived(workflowId, workflowOwner, reportId);

        _processReport(metadata, report);
    }

    /**
     * @notice Domain logic for a validated CRE report.
     * @dev `metadata` is already forwarder-/identity-checked; decode `report` as your workflow ABI.
     */
    function _processReport(bytes calldata metadata, bytes calldata report) internal virtual;

    // --------------------------------------------
    //  Admin (internal — child exposes role-gated wrappers)
    // --------------------------------------------

    /// @dev WARNING: `address(0)` disables forwarder validation (anyone can call `onReport`).
    function _setForwarderAddress(address forwarder_) internal {
        address previous = _forwarder;
        if (forwarder_ == address(0)) {
            emit SecurityWarning("Forwarder address set to zero - contract is now INSECURE");
        }
        _forwarder = forwarder_;
        emit ForwarderAddressUpdated(previous, forwarder_);
    }

    function _setExpectedAuthor(address author_) internal {
        address previous = _expectedAuthor;
        _expectedAuthor = author_;
        emit ExpectedAuthorUpdated(previous, author_);
    }

    /// @dev Empty string clears the check. Name validation requires author validation.
    function _setExpectedWorkflowName(string memory name_) internal {
        bytes10 previous = _expectedWorkflowName;
        if (bytes(name_).length == 0) {
            _expectedWorkflowName = bytes10(0);
            emit ExpectedWorkflowNameUpdated(previous, bytes10(0));
            return;
        }

        // Chainlink convention: SHA256 → hex string → first 10 ASCII chars as bytes10.
        bytes32 hash = sha256(bytes(name_));
        bytes memory hexString = _bytesToHexString(abi.encodePacked(hash));
        bytes memory first10 = new bytes(10);
        for (uint256 i; i < 10; ++i) {
            first10[i] = hexString[i];
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _expectedWorkflowName = bytes10(first10);
        emit ExpectedWorkflowNameUpdated(previous, _expectedWorkflowName);
    }

    function _setExpectedWorkflowId(bytes32 id_) internal {
        bytes32 previous = _expectedWorkflowId;
        _expectedWorkflowId = id_;
        emit ExpectedWorkflowIdUpdated(previous, id_);
    }

    // --------------------------------------------
    //  Metadata helpers
    // --------------------------------------------

    /**
     * @notice Decodes CRE forwarder metadata.
     * @dev Accepts 62-byte packed identity or production 64-byte slice (+ `reportId`).
     */
    function _decodeMetadata(bytes calldata metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner, bytes2 reportId)
    {
        uint256 length = metadata.length;
        if (length != 62 && length != 64) revert InvalidMetadataLength(length);

        workflowId = bytes32(metadata[0:32]);
        workflowName = bytes10(metadata[32:42]);
        workflowOwner = address(bytes20(metadata[42:62]));
        if (length == 64) {
            reportId = bytes2(metadata[62:64]);
        }
    }

    // --------------------------------------------
    //  ERC165
    // --------------------------------------------

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ICreReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _bytesToHexString(bytes memory data) private pure returns (bytes memory) {
        bytes memory hexString = new bytes(data.length * 2);
        for (uint256 i; i < data.length; ++i) {
            hexString[i * 2] = HEX_CHARS[uint8(data[i] >> 4)];
            hexString[i * 2 + 1] = HEX_CHARS[uint8(data[i] & 0x0f)];
        }
        return hexString;
    }
}
