// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreateParams } from "@doppler/src/Airlock.sol";
import { FeeDistributionInfo } from "@doppler/src/types/RehypeTypes.sol";
import { DopplerTypes } from "@types/lockers/DopplerTypes.sol";

/**
 * @title IDopplerConfig
 * @notice Shared launch recipe + Doppler module addresses for `DopplerLocker`.
 */
interface IDopplerConfig {
    function initialSupply() external view returns (uint256);

    function dn404Unit() external view returns (uint256);

    function tokenFactory() external view returns (address);

    function vaultFactory() external view returns (address);

    function airlock() external view returns (address);

    function governanceFactory() external view returns (address);

    function poolInitializer() external view returns (address);

    function liquidityMigrator() external view returns (address);

    function rehypeHookInitializer() external view returns (address);

    function rehypeHookMigrator() external view returns (address);

    function stakeVesting() external view returns (address);

    function hpTreasury() external view returns (address);

    function bondingCurves() external view returns (DopplerTypes.Curve[] memory);

    function marketLaunchConfig() external view returns (DopplerTypes.MarketLaunchConfig memory);

    /**
     * @notice Module bundle used by `buildCreateParams`.
     * @param feeRouterFactory_ Per-market FeeRouter factory (HP infra; lives on locker).
     * @param integrator_ Airlock integrator (`Orchestrator`).
     */
    function dopplerModules(
        address feeRouterFactory_,
        address integrator_
    ) external view returns (DopplerTypes.DopplerModules memory);

    /**
     * @notice Full `CreateParams` for `Airlock.create` (encoding lives here, not on the locker).
     * @param feeRouterFactory_ Per-market FeeRouter factory (HP infra; lives on locker).
     * @param integrator_ Airlock integrator (`Orchestrator`).
     */
    function buildCreateParams(
        string calldata name,
        string calldata symbol,
        string calldata baseURI_,
        address feeRouter,
        bytes32 salt,
        address feeRouterFactory_,
        address integrator_
    ) external view returns (CreateParams memory);

    function setMarketLaunchConfig(DopplerTypes.MarketLaunchConfig memory config_) external;

    function setBondingCurves(DopplerTypes.Curve[] memory curves_) external;

    function setGraduationPolicy(uint256 minGraduateProceeds_, uint32 minBondingDuration_) external;

    function setFeeDistribution(FeeDistributionInfo calldata feeDistribution_) external;

    function configureDeployModules(address tokenFactory_, address vaultFactory_, address airlock_) external;

    function configureDopplerModules(
        address governanceFactory_,
        address poolInitializer_,
        address liquidityMigrator_,
        address rehypeHookInitializer_,
        address rehypeHookMigrator_
    ) external;

    function configureLaunchpadRecipients(address stakeVesting_, address hpTreasury_) external;
}
