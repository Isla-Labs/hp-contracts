// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/*
Two core functions:
1) fetchRoundsLatest()
2) fetchRoundsHistorical()

Each interacts with the oracle to fetch and format the matchweek data.
Super simple. Once done, PbrTreasury reads round data from here for its tournamentId.
*/