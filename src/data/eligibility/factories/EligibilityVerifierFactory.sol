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
 *      Grant Automator `CATEGORY_THREE` to the **proxy** address, not the implementation.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifierFactory {
    /// @notice Shared `EligibilityVerifier` logic (RateLimit cooldown fixed at deploy).
    address public immutable implementation;

    /// @notice Initial owner of each proxy's `ProxyAdmin` (upgrade authority).
    address public immutable proxyAdminOwner;

    /**
     * @param cooldown_ Global `verifyEligibility` cooldown for the shared implementation.
     * @param proxyAdminOwner_ Owns each TUP `ProxyAdmin` (e.g. `ConstitutionalTimelock`).
     */
    constructor(uint256 cooldown_, address proxyAdminOwner_) {
        if (proxyAdminOwner_ == address(0)) revert Errors.ZeroAddress();
        implementation = address(new EligibilityVerifier(cooldown_));
        proxyAdminOwner = proxyAdminOwner_;
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
        address automator,
        bytes32 leagueId,
        uint16 baseYear
    ) external returns (address proxy) {
        bytes memory initData = abi.encodeCall(
            EligibilityVerifier.initialize,
            (
                forwarder,
                expectedWorkflowId,
                playerSetRegistry,
                tournamentRegistry,
                ppmVerifier,
                deployDoppler,
                automator,
                leagueId,
                baseYear
            )
        );

        proxy = address(new TransparentUpgradeableProxy(implementation, proxyAdminOwner, initData));
        emit Events.EligibilityVerifierProxyCreated(proxy, leagueId, implementation);
    }
}
