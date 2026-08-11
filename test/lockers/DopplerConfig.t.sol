// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeploymentsErrors as Errors } from "@errors/lockers/DeploymentsErrors.sol";
import { DopplerTypes } from "@types/lockers/DopplerTypes.sol";
import { DopplerConfig } from "@src/lockers/assets/deploy/config/DopplerConfig.sol";
import { CreateParams } from "@doppler/src/Airlock.sol";
import { WAD } from "@doppler/src/types/Wad.sol";

import { LockersTestBase } from "./LockersTestBase.sol";

contract DopplerConfigTest is LockersTestBase {
    function test_constructor_defaults() public view {
        assertEq(dopplerConfig.initialSupply(), 22_000_000 ether);
        assertEq(dopplerConfig.numTokensToSell(), 20_000_000 ether);
        assertEq(dopplerConfig.tickSpacing(), 8);
        assertEq(dopplerConfig.dn404Unit(), 1000 ether);
        assertEq(dopplerConfig.minGraduateProceeds(), 50 ether);
        assertEq(dopplerConfig.minBondingDuration(), 30 days);
        assertEq(dopplerConfig.airlock(), address(airlock));
        assertEq(dopplerConfig.stakeVesting(), address(stakeVesting));
        assertEq(dopplerConfig.hpTreasury(), hpTreasury);

        DopplerTypes.Curve[] memory curves = dopplerConfig.bondingCurves();
        assertEq(curves.length, 4);
        uint256 total;
        for (uint256 i; i < curves.length; ++i) {
            total += curves[i].shares;
        }
        assertEq(total, WAD);
    }

    function test_setMarketLaunchConfig_revertsInvalidSupply() public {
        DopplerTypes.MarketLaunchConfig memory cfg = dopplerConfig.marketLaunchConfig();
        cfg.numTokensToSell = cfg.initialSupply + 1;

        vm.expectRevert(Errors.InvalidLaunchSupply.selector);
        _timelockCall(address(dopplerConfig), abi.encodeCall(DopplerConfig.setMarketLaunchConfig, (cfg)));
    }

    function test_setBondingCurves_revertsEmpty() public {
        DopplerTypes.Curve[] memory empty = new DopplerTypes.Curve[](0);
        vm.expectRevert(Errors.EmptyCurves.selector);
        _timelockCall(address(dopplerConfig), abi.encodeCall(DopplerConfig.setBondingCurves, (empty)));
    }

    function test_setBondingCurves_revertsBadShares() public {
        DopplerTypes.Curve[] memory curves = new DopplerTypes.Curve[](1);
        curves[0] = DopplerTypes.Curve({ tickLower: -100, tickUpper: -10, numPositions: 1, shares: WAD / 2 });

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCurveShares.selector, WAD / 2));
        _timelockCall(address(dopplerConfig), abi.encodeCall(DopplerConfig.setBondingCurves, (curves)));
    }

    function test_buildCreateParams_happy() public {
        address feeRouter = makeAddr("feeRouter");
        CreateParams memory params = dopplerConfig.buildCreateParams(
            "Player", "PLY", "ipfs://cid/", feeRouter, bytes32(uint256(1)), address(feeRouterFactory), hpTreasury
        );

        assertEq(params.initialSupply, 22_000_000 ether);
        assertEq(params.numTokensToSell, 20_000_000 ether);
        assertEq(params.salt, bytes32(uint256(1)));
        assertEq(params.integrator, hpTreasury);
        assertTrue(params.tokenFactoryData.length > 0);
        assertTrue(params.poolInitializerData.length > 0);
    }

    function test_buildCreateParams_revertsZeroIntegrator() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        dopplerConfig.buildCreateParams(
            "Player",
            "PLY",
            "ipfs://cid/",
            makeAddr("feeRouter"),
            bytes32(uint256(1)),
            address(feeRouterFactory),
            address(0)
        );
    }

    function test_admin_onlyTimelock() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Errors.Unauthorized.selector);
        dopplerConfig.setGraduationPolicy(1 ether, 1 days);
    }
}
