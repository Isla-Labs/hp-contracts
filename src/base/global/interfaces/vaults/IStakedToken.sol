// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IStakedToken
 * @notice Soulbound staked receipt token for a single `PlayerVault`.
 */
interface IStakedToken {
    function vault() external view returns (address);

    /// @notice ERC-7572 contract-level metadata URI (`ipfs://…` JSON with image).
    function contractURI() external view returns (string memory);

    function balanceOfAt(address account, uint256 blockNumber) external view returns (uint256);

    function totalSupplyAt(uint256 blockNumber) external view returns (uint256);

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
