// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { PoolKey } from "@v4-core/types/PoolKey.sol";

/**
 * @title IDopplerHookInitializer
 * @notice Narrow `DopplerHookInitializer` view surface (avoids Quoter solc pin).
 */
interface IDopplerHookInitializer {
    function getState(address asset)
        external
        view
        returns (
            address numeraire,
            uint256 totalTokensOnBondingCurve,
            address dopplerHook,
            bytes memory graduationDopplerHookCalldata,
            uint8 status,
            PoolKey memory poolKey,
            int24 farTick
        );
}
