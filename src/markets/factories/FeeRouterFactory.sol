// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { BeaconProxy } from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { FeeRouter } from "@markets/FeeRouter.sol";

/**
 * @title FeeRouterFactory
 * @notice Deploys per-market `BeaconProxy` FeeRouters sharing one `UpgradeableBeacon`.
 * @dev Upgradeable factory (InitGuard TUP). Beacon ownership → Orchestrator.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouterFactory is Initializable, AddressBook, Ownable {
    /// @notice Shared beacon; upgrade to change logic for every market FeeRouter
    UpgradeableBeacon public beacon;

    /// @notice Owns the beacon (logic upgrades); sole caller of `create`
    address public orchestrator;

    /// @notice Idempotent resume: `playerId` → deployed FeeRouter (zero until first create).
    mapping(bytes32 playerId => address feeRouter) public feeRouterOf;

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @notice Resolve Orchestrator, deploy shared FeeRouter beacon.
    function initialize() external initializer {
        orchestrator = _getAddress(_addressKey(Addresses.ORCHESTRATOR));
        address impl = address(new FeeRouter(address(addressProvider)));
        beacon = new UpgradeableBeacon(impl, orchestrator);
        _transferOwnership(orchestrator);
    }

    /**
     * @notice Deploy a BeaconProxy FeeRouter for `playerId`, or return the existing one.
     * @dev Idempotent so DopplerLocker deploy retries do not orphan FeeRouters after a
     *      partial `_onDeployReady` failure.
     * @param playerId Player identity associated with the FeeRouter.
     * @param pbrFeeHub League `PbrFeeHub` (zero = unsupported even-split). Ignored if
     *        a FeeRouter already exists for `playerId` (use `FeeRouter.setPbrFeeHub` to change).
     * @return feeRouter Address of the FeeRouter BeaconProxy.
     */
    function create(bytes32 playerId, address pbrFeeHub) external returns (address feeRouter) {
        if (msg.sender != orchestrator) revert Errors.Unauthorized();
        if (playerId == bytes32(0)) revert Errors.ZeroId();

        feeRouter = feeRouterOf[playerId];
        if (feeRouter != address(0)) return feeRouter;

        bytes memory initData = abi.encodeCall(FeeRouter.initialize, (playerId, pbrFeeHub));

        feeRouter = address(new BeaconProxy(address(beacon), initData));
        feeRouterOf[playerId] = feeRouter;

        emit Events.FeeRouterCreated(playerId, feeRouter, pbrFeeHub);
    }

    /// @notice Current FeeRouter implementation pointed to by the shared beacon
    function implementation() external view returns (address) {
        return beacon.implementation();
    }
}
