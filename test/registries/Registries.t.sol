// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";

import { AssetRegistry } from "../../src/AssetRegistry.sol";
import { TournamentRegistry } from "../../src/TournamentRegistry.sol";
import {
    AdvancedTradeData,
    AssetData,
    MarketStatus,
    PlayerVaultData,
    RegistryData,
    SpotMarketData
} from "@base/global/types/AssetTypes.sol";
import {
    ActiveMatchweek,
    LeagueData,
    MatchweekInfo,
    Season
} from "@base/global/types/TournamentTypes.sol";

contract AssetRegistryTest is Test {
    AssetRegistry registry;
    address token = makeAddr("token");

    function setUp() public {
        registry = new AssetRegistry(address(this));
    }

    function test_createAsset_andGetters() public {
        AssetData memory data = _sampleAsset(token, bytes32("player"), bytes32("league"));
        registry.createAsset(token, data);

        AssetData memory got = registry.getAssetData(token);
        assertEq(got.token, token);
        assertEq(got.playerId, bytes32("player"));
        assertEq(got.leagueId, bytes32("league"));
        assertEq(registry.tokenOfPlayerId(bytes32("player")), token);
        assertTrue(registry.exists(token));
        assertEq(registry.tokenCount(), 1);
        assertEq(registry.tokenAt(0), token);
    }

    function test_createAsset_revertsDuplicatePlayerId() public {
        registry.createAsset(token, _sampleAsset(token, bytes32("player"), bytes32("league")));
        address other = makeAddr("other");
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.PlayerIdTaken.selector, bytes32("player"), token));
        registry.createAsset(other, _sampleAsset(other, bytes32("player"), bytes32("league2")));
    }

    function test_setMarketStatus_graduated() public {
        registry.createAsset(token, _sampleAsset(token, bytes32("p"), bytes32("l")));
        registry.setMarketStatus(token, MarketStatus.GRADUATED);
        AssetData memory got = registry.getAssetData(token);
        assertEq(uint8(got.marketStatus), uint8(MarketStatus.GRADUATED));
        assertGt(got.registryData.graduatedAt, 0);
    }

    function test_setUtilized() public {
        registry.createAsset(token, _sampleAsset(token, bytes32("p"), bytes32("l")));
        registry.setUtilized(token, false);
        assertFalse(registry.getAssetData(token).registryData.playerVaultData.isUtilized);
    }

    function _sampleAsset(address t, bytes32 playerId, bytes32 leagueId) internal view returns (AssetData memory data) {
        data.playerId = playerId;
        data.leagueId = leagueId;
        data.token = t;
        data.symbol = "PLY";
        data.marketStatus = MarketStatus.BONDING;
        data.registryData = RegistryData({
            spotMarketData: SpotMarketData({
                activePool: PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(t),
                    fee: 3000,
                    tickSpacing: 60,
                    hooks: IHooks(address(0))
                }),
                hookDoppler: address(0),
                hookMigrator: address(0),
                feeRouter: address(0)
            }),
            advancedTradeData: AdvancedTradeData({ advancedTradeVault: address(0), markSource: address(0) }),
            playerVaultData: PlayerVaultData({ playerVault: address(0), stToken: address(0), isUtilized: true }),
            deployedAt: 0,
            graduatedAt: 0,
            deactivatedAt: 0
        });
    }
}

contract TournamentRegistryTest is Test {
    TournamentRegistry registry;
    bytes32 leagueId = bytes32("EPL");

    function setUp() public {
        registry = new TournamentRegistry(address(this));
    }

    function test_createLeague_andMatchweek() public {
        bytes32[] memory fixtures = new bytes32[](2);
        fixtures[0] = bytes32("f1");
        fixtures[1] = bytes32("f2");

        MatchweekInfo memory mw = MatchweekInfo({
            activeMatchweek: ActiveMatchweek({
                activeMatchweek: 1,
                unixStartTime: 1_000,
                unixEndTime: 2_000,
                fixtureUuids: fixtures
            }),
            tradingMatchweek: 1,
            totalMatchweeks: 38
        });

        registry.createLeague(leagueId, makeAddr("treasury"), mw);

        LeagueData memory league = registry.getLeagueData(leagueId);
        assertEq(league.leagueId, leagueId);
        assertEq(league.pbrTreasury, makeAddr("treasury"));
        assertEq(league.matchweekInfo.activeMatchweek.activeMatchweek, 1);
        assertEq(league.matchweekInfo.activeMatchweek.fixtureUuids.length, 2);
        assertEq(registry.getFixtureUuids(leagueId)[0], bytes32("f1"));
        assertEq(registry.leagueCount(), 1);
    }

    function test_setFixtureUuids_replaces() public {
        MatchweekInfo memory mw = MatchweekInfo({
            activeMatchweek: ActiveMatchweek({
                activeMatchweek: 1,
                unixStartTime: 1_000,
                unixEndTime: 2_000,
                fixtureUuids: new bytes32[](0)
            }),
            tradingMatchweek: 1,
            totalMatchweeks: 38
        });
        registry.createLeague(leagueId, makeAddr("treasury"), mw);

        bytes32[] memory fixtures = new bytes32[](1);
        fixtures[0] = bytes32("fx");
        registry.setFixtureUuids(leagueId, fixtures);
        assertEq(registry.getFixtureUuids(leagueId).length, 1);
        assertEq(registry.getFixtureUuids(leagueId)[0], bytes32("fx"));
    }

    function test_addSeason() public {
        MatchweekInfo memory mw = MatchweekInfo({
            activeMatchweek: ActiveMatchweek({
                activeMatchweek: 1,
                unixStartTime: 1_000,
                unixEndTime: 2_000,
                fixtureUuids: new bytes32[](0)
            }),
            tradingMatchweek: 1,
            totalMatchweeks: 38
        });
        registry.createLeague(leagueId, makeAddr("treasury"), mw);

        Season memory season;
        season.seasonId = bytes32("2425");
        season.seasonStartTime = 1_000;
        season.seasonEndTime = 9_000;
        registry.addSeason(leagueId, season);

        assertEq(registry.seasonCount(leagueId), 1);
        assertEq(registry.getSeason(leagueId, 0).seasonId, bytes32("2425"));
    }

    function test_createLeague_revertsInvalidWindow() public {
        MatchweekInfo memory mw = MatchweekInfo({
            activeMatchweek: ActiveMatchweek({
                activeMatchweek: 1,
                unixStartTime: 2_000,
                unixEndTime: 1_000,
                fixtureUuids: new bytes32[](0)
            }),
            tradingMatchweek: 1,
            totalMatchweeks: 38
        });
        vm.expectRevert(TournamentRegistry.InvalidWindow.selector);
        registry.createLeague(leagueId, makeAddr("treasury"), mw);
    }
}
