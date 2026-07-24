// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @notice One verified Automator caller and the destinations it may hit.
 * @dev Destinations are enforced in `executeAutomation`; target contracts still self-gate.
 */
struct VerifiedCallerConfig {
    address caller;
    address[] destinations;
}

// --------------------------------------------
//  Draft graphs for future scoping docs
// --------------------------------------------

// EligibilityVerifier → Automator → DopplerLocker / TransferLocker
struct EligibilityAutomation {
    address verifier;
    address dopplerLocker;
    address transferLocker;
}

// RoundManager → Automator → TournamentRegistry (+ optional PlayerSetRegistry)
struct MatchweeksAutomation {
    address roundManager;
    address tournamentRegistry;
    address playerSetRegistry;
}

struct PpmAutomation {
    address ppmManager;
    address ppmLocker;
}
