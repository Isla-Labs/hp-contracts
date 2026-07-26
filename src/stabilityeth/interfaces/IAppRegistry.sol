// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

interface IAppRegistry {
    function isBeneficiary(bytes32 appId, address account) external view returns (bool);

    function beneficiaryShareBps(bytes32 appId, address account) external view returns (uint16);

    function isRegistered(bytes32 appId) external view returns (bool);

    function isActive(bytes32 appId) external view returns (bool);

    function minterOf(bytes32 appId) external view returns (address);

    function pbrTreasury() external view returns (address);

    /// @notice Cumulative SETH minted through the app's minter (CRE mint-delta source)
    function totalMinted(bytes32 appId) external view returns (uint256);

    /// @notice Outstanding SETH minted via the app's minter minus burned via it (PBR eligibility gate)
    function netMinted(bytes32 appId) external view returns (uint256);

    function recordMint(uint256 sethAmount) external;

    function recordBurn(uint256 sethAmount) external;
}
