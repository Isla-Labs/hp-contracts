// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Oracle } from "@base/abstract/Oracle.sol";
import { CvmJob, VanityDeployKind } from "@types/oracle/CvmTypes.sol";

/**
 * @title TestData
 * @notice Sepolia consumer for CVM `VanitySalts` end-to-end smokes.
 * @dev Flow: `requestAsset` / `requestTournament` → `CvmRouter` → attested worker mines
 *      vanity salts → `_fulfillRequest` stores results for inspection.
 *
 *      This consumer is also a sketch for future deploy state machines:
 *        - `VanityDeployKind` selects which salt set is requested / returned
 *        - unused response slots are zeroed (Asset clears treasury; Tournament clears token/vault)
 *        - entrypoints stay kind-specific so callers don't pack unused factory args
 *
 *      Args (v1):
 *        `abi.encode(VanityDeployKind kind, bytes32 seed,
 *                    address tokenFactory, bytes32 tokenInitCodeHash, address vaultFactory,
 *                    address treasuryFactory)`
 *      Response (v1):
 *        `abi.encode(VanityDeployKind kind,
 *                    bytes32 tokenSalt, address tokenPredicted,
 *                    bytes32 vaultSalt, address vaultPredicted,
 *                    bytes32 treasurySalt, address treasuryPredicted)`
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TestData is Oracle {
    /// @notice Kind of the last successful fulfill (`None` if last fulfill had `err`).
    VanityDeployKind public lastKind;

    /// @notice CREATE2 salt for a `0x22…` PlayerToken (Asset only).
    bytes32 public lastTokenSalt;

    /// @notice Predicted PlayerToken address for `lastTokenSalt`.
    address public lastTokenPredicted;

    /// @notice CreateX salt for a `0x42…` PlayerVault (Asset only).
    bytes32 public lastVaultSalt;

    /// @notice Predicted PlayerVault address for `lastVaultSalt`.
    address public lastVaultPredicted;

    /// @notice CreateX salt for a `0x99…` PbrTreasury (Tournament only).
    bytes32 public lastTreasurySalt;

    /// @notice Predicted PbrTreasury address for `lastTreasurySalt`.
    address public lastTreasuryPredicted;

    /// @notice Raw error bytes from the last fulfill (`0x` on success).
    bytes public lastError;

    /// @notice Request id of the last fulfill callback.
    bytes32 public lastFulfilledId;

    event SaltsRequested(
        bytes32 indexed requestId,
        VanityDeployKind kind,
        bytes32 seed,
        address tokenFactory,
        bytes32 tokenInitCodeHash,
        address vaultFactory,
        address treasuryFactory
    );
    event SaltsReceived(
        bytes32 indexed requestId,
        VanityDeployKind kind,
        bytes32 tokenSalt,
        address tokenPredicted,
        bytes32 vaultSalt,
        address vaultPredicted,
        bytes32 treasurySalt,
        address treasuryPredicted,
        bytes err
    );

    /**
     * @param router_ Live `CvmRouter` (Base Sepolia: see `deployments/base-sepolia-oracle.json`).
     * @param fulfillGasLimit_ Callback gas for `_fulfillRequest` (e.g. 300_000).
     */
    constructor(address router_, uint32 fulfillGasLimit_) Oracle(router_, CvmJob.VanitySalts, fulfillGasLimit_) { }

    /**
     * @notice Mine PlayerToken (`0x22`) + PlayerVault (`0x42`) salts.
     * @param tokenFactory_ `DN404Factory` (CREATE2 deployer).
     * @param tokenInitCodeHash_ `keccak256(DopplerDN404 creationCode || ctor args)`.
     * @param vaultFactory_ `PlayerVaultFactory` (permissioned CreateX caller).
     * @param seed_ Mining entropy (e.g. `playerId`).
     */
    function requestAsset(
        address tokenFactory_,
        bytes32 tokenInitCodeHash_,
        address vaultFactory_,
        bytes32 seed_
    ) external returns (bytes32 requestId) {
        return _request(
            VanityDeployKind.Asset,
            seed_,
            tokenFactory_,
            tokenInitCodeHash_,
            vaultFactory_,
            address(0)
        );
    }

    /**
     * @notice Mine PbrTreasury (`0x99`) salt.
     * @param treasuryFactory_ `PbrTreasuryFactory` (permissioned CreateX caller).
     * @param seed_ Mining entropy (e.g. `tournamentId`).
     */
    function requestTournament(address treasuryFactory_, bytes32 seed_) external returns (bytes32 requestId) {
        return _request(VanityDeployKind.Tournament, seed_, address(0), bytes32(0), address(0), treasuryFactory_);
    }

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        lastFulfilledId = requestId;
        lastError = err;

        if (err.length == 0 && response.length > 0) {
            (
                lastKind,
                lastTokenSalt,
                lastTokenPredicted,
                lastVaultSalt,
                lastVaultPredicted,
                lastTreasurySalt,
                lastTreasuryPredicted
            ) = abi.decode(response, (VanityDeployKind, bytes32, address, bytes32, address, bytes32, address));
        } else {
            _clearSalts();
        }

        emit SaltsReceived(
            requestId,
            lastKind,
            lastTokenSalt,
            lastTokenPredicted,
            lastVaultSalt,
            lastVaultPredicted,
            lastTreasurySalt,
            lastTreasuryPredicted,
            err
        );
    }

    function _request(
        VanityDeployKind kind,
        bytes32 seed_,
        address tokenFactory_,
        bytes32 tokenInitCodeHash_,
        address vaultFactory_,
        address treasuryFactory_
    ) private returns (bytes32 requestId) {
        requestId = _sendOracleRequest(
            abi.encode(kind, seed_, tokenFactory_, tokenInitCodeHash_, vaultFactory_, treasuryFactory_)
        );
        emit SaltsRequested(
            requestId, kind, seed_, tokenFactory_, tokenInitCodeHash_, vaultFactory_, treasuryFactory_
        );
    }

    function _clearSalts() private {
        lastKind = VanityDeployKind.None;
        lastTokenSalt = bytes32(0);
        lastTokenPredicted = address(0);
        lastVaultSalt = bytes32(0);
        lastVaultPredicted = address(0);
        lastTreasurySalt = bytes32(0);
        lastTreasuryPredicted = address(0);
    }
}
