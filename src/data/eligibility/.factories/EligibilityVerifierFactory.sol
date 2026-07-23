// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TransparentUpgradeableProxy } from "@openzeppelin/proxy/transparent/TransparentUpgradeableProxy.sol";

import { EligibilityErrors as Errors } from "@base/global/libraries/errors/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@base/global/libraries/events/EligibilityEvents.sol";
import { EligibilityVerifier } from "@src/data/eligibility/EligibilityVerifier.sol";

/**
 * @title EligibilityVerifierFactory
 * @notice Deploys per-league `EligibilityVerifier` behind `TransparentUpgradeableProxy`.
 * @dev Shared implementation (cooldown baked in). Each `create` deploys a new proxy whose
 *      `ProxyAdmin` owner is `proxyAdminOwner` (typically `ConstitutionalTimelock`).
 *      Wire `DeployDoppler.setEligibilityVerifier(proxy)` and
 *      `ManageLifecycle.setEligibilityVerifier(proxy)` after create.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifierFactory {
    /// @notice Shared `EligibilityVerifier` logic (RateLimit cooldown fixed at deploy).
    address public immutable implementation;

    /// @notice Initial owner of each proxy's `ProxyAdmin` (upgrade authority).
    address public immutable proxyAdminOwner;

    /// @notice Granted `CATEGORY_ONE` on each verifier (`EligibilityCriteria` updates).
    address public immutable constitutionalTimelock;

    /// @notice Granted `DEFAULT_ADMIN_ROLE` on each verifier.
    address public immutable dao;

    /**
     * @param cooldown_ Global `verifyEligibility` cooldown for the shared implementation.
     * @param proxyAdminOwner_ Owns each TUP `ProxyAdmin` (e.g. `ConstitutionalTimelock`).
     * @param constitutionalTimelock_ `CATEGORY_ONE` on criteria.
     * @param dao_ `DEFAULT_ADMIN_ROLE` on criteria.
     */
    constructor(
        uint256 cooldown_,
        address proxyAdminOwner_,
        address constitutionalTimelock_,
        address dao_
    ) {
        if (proxyAdminOwner_ == address(0) || constitutionalTimelock_ == address(0) || dao_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        implementation = address(new EligibilityVerifier(cooldown_));
        proxyAdminOwner = proxyAdminOwner_;
        constitutionalTimelock = constitutionalTimelock_;
        dao = dao_;
    }

    /**
     * @notice Deploy + initialize a league EligibilityVerifier proxy.
     * @return proxy The `TransparentUpgradeableProxy` address (use this everywhere).
     */
    function create(
        address forwarder,
        bytes32 expectedWorkflowId,
        address playerSetRegistry,
        address tournamentRegistry,
        address ppmVerifier,
        address deployDoppler,
        address manageLifecycle,
        bytes32 leagueId,
        uint16 baseYear
    ) external returns (address proxy) {
        bytes memory initData = abi.encodeCall(
            EligibilityVerifier.initialize,
            (
                constitutionalTimelock,
                dao,
                forwarder,
                expectedWorkflowId,
                playerSetRegistry,
                tournamentRegistry,
                ppmVerifier,
                deployDoppler,
                manageLifecycle,
                leagueId,
                baseYear
            )
        );

        proxy = address(new TransparentUpgradeableProxy(implementation, proxyAdminOwner, initData));
        emit Events.EligibilityVerifierProxyCreated(proxy, leagueId, implementation);
    }
}
