// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 *   Responsible for sending m and M_adj values to respective PBRTreasury implementations at
 *   mwEndTime.
 *     - Needs to integrate with Digests that are stored onchain for trustless raw stat collection
 *     - Needs to integrate with offchain zkVM for trustless PPM conversion
 */