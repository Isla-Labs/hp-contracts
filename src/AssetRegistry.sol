// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AssetData } from "@base/global/types/AssetTypes.sol";

contract AssetRegistry {
    mapping(address token => AssetData assetData) public assetData;

    function createAsset(address token, AssetData memory _assetData) external {
        assetData[token] = _assetData;
    }

    function getAssetData(address token) external view returns (AssetData memory) {
        return assetData[token];
    }
}
