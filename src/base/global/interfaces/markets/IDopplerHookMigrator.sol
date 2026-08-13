// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @title IDopplerHookMigrator
 * @notice Narrow `DopplerHookMigrator` view surface (avoids Quoter solc pin).
 */
interface IDopplerHookMigrator {
    function getPair(address asset) external view returns (address token0, address token1);

    function getAssetData(
        address token0,
        address token1
    )
        external
        view
        returns (
            bool isToken0,
            PoolKey memory poolKey,
            uint32 lockDuration,
            uint24 feeOrInitialDynamicFee,
            bool useDynamicFee,
            address dopplerHook,
            bytes memory onInitializationCalldata,
            uint8 status
        );
}
