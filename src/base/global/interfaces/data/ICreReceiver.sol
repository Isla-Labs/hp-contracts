// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IReceiver } from "@cre/v1/interfaces/IReceiver.sol";

/**
 * @title ICreReceiver
 * @notice Deprecated alias for Chainlink Keystone `IReceiver`.
 * @dev Prefer importing cre/v1/interfaces/IReceiver.sol via the `@cre` remapping.
 *      Kept so existing HP references resolve to the canonical interface.
 */
interface ICreReceiver is IReceiver { }
