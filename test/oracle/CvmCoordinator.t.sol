// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { CvmCoordinator } from "@src/oracle/CvmCoordinator.sol";
import { MockAttestationVerifier } from "@src/oracle/attestation/MockAttestationVerifier.sol";
import { AttestationLib } from "@src/oracle/attestation/AttestationLib.sol";
import { AttestationClaim, OracleRegistration } from "@types/oracle/CvmTypes.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { CvmErrors as Errors } from "@errors/oracle/CvmErrors.sol";
import { MockDstackApp } from "./mocks/MockDstackApp.sol";

contract CvmCoordinatorTest is Test {
    address internal dao = makeAddr("dao");
    address internal constitutional = makeAddr("constitutional");
    address internal transmitter = makeAddr("transmitter");
    address internal transmitter2 = makeAddr("transmitter2");

    bytes32 internal constant DEVICE = keccak256("device-1");
    bytes32 internal constant COMPOSE_V1 = keccak256("compose-v1");
    bytes32 internal constant COMPOSE_V2 = keccak256("compose-v2");

    uint64 internal constant TTL = 1 days;
    uint64 internal constant MAX_QUOTE_AGE = 1 hours;

    MockDstackApp internal dstack;
    MockAttestationVerifier internal verifier;
    CvmCoordinator internal coordinator;

    function setUp() public {
        dstack = new MockDstackApp(address(this));
        verifier = new MockAttestationVerifier(MAX_QUOTE_AGE);
        coordinator = new CvmCoordinator(dao, constitutional, address(0), address(verifier), TTL);

        dstack.transferOwnership(address(coordinator));

        vm.prank(dao);
        coordinator.setDstackApp(address(dstack));

        vm.prank(dao);
        coordinator.addComposeHash(COMPOSE_V1);
    }

    function _claim(
        address txmitter,
        bytes32 deviceId,
        bytes32 composeHash,
        bytes32 nonce
    ) internal view returns (AttestationClaim memory) {
        return AttestationClaim({
            transmitter: txmitter,
            deviceId: deviceId,
            composeHash: composeHash,
            nonce: nonce,
            quotedAt: uint64(block.timestamp)
        });
    }

    function test_registerOracle_attestation_setsLiveOracle() public {
        AttestationClaim memory claim = _claim(transmitter, DEVICE, COMPOSE_V1, keccak256("n1"));
        bytes memory attestation = abi.encode(claim);

        coordinator.registerOracle(attestation);

        assertTrue(coordinator.isOracle(transmitter));
        OracleRegistration memory reg = coordinator.getRegistration(transmitter);
        assertEq(reg.deviceId, DEVICE);
        assertEq(reg.composeHash, COMPOSE_V1);
        assertEq(reg.expiresAt, uint64(block.timestamp) + TTL);
        assertTrue(reg.active);
        assertEq(
            AttestationLib.reportDataCommitment(claim),
            keccak256(abi.encode(transmitter, DEVICE, COMPOSE_V1, claim.nonce))
        );
    }

    function test_isOracle_falseAfterTtl() public {
        AttestationClaim memory claim = _claim(transmitter, DEVICE, COMPOSE_V1, keccak256("n2"));
        coordinator.registerOracle(abi.encode(claim));
        assertTrue(coordinator.isOracle(transmitter));

        vm.warp(block.timestamp + TTL + 1);
        assertFalse(coordinator.isOracle(transmitter));
    }

    function test_isOracle_falseWhenComposeRemovedFromPolicy() public {
        AttestationClaim memory claim = _claim(transmitter, DEVICE, COMPOSE_V1, keccak256("n3"));
        coordinator.registerOracle(abi.encode(claim));
        assertTrue(coordinator.isOracle(transmitter));

        vm.prank(dao);
        coordinator.setAttestationComposeAllowed(COMPOSE_V1, false);

        assertFalse(coordinator.isOracle(transmitter));
    }

    function test_registerOracle_revertsWhenComposeNotAllowed() public {
        AttestationClaim memory claim = _claim(transmitter, DEVICE, COMPOSE_V2, keccak256("n4"));
        vm.expectRevert(abi.encodeWithSelector(Errors.ComposeNotAllowed.selector, COMPOSE_V2));
        coordinator.registerOracle(abi.encode(claim));
    }

    function test_registerOracle_refreshExtendsTtl() public {
        AttestationClaim memory c1 = _claim(transmitter, DEVICE, COMPOSE_V1, keccak256("n5"));
        coordinator.registerOracle(abi.encode(c1));
        uint64 firstExpiry = coordinator.getRegistration(transmitter).expiresAt;

        // Stay within maxQuoteAge while advancing toward TTL refresh.
        vm.warp(block.timestamp + MAX_QUOTE_AGE / 2);
        AttestationClaim memory c2 = _claim(transmitter, DEVICE, COMPOSE_V1, keccak256("n6"));
        c2.quotedAt = uint64(block.timestamp);
        coordinator.registerOracle(abi.encode(c2));

        uint64 secondExpiry = coordinator.getRegistration(transmitter).expiresAt;
        assertGt(secondExpiry, firstExpiry);
        assertTrue(coordinator.isOracle(transmitter));
    }

    function test_upgradePath_v1DeniedV2Allowed() public {
        AttestationClaim memory v1 = _claim(transmitter, DEVICE, COMPOSE_V1, keccak256("n7"));
        coordinator.registerOracle(abi.encode(v1));

        vm.startPrank(dao);
        coordinator.addComposeHash(COMPOSE_V2);
        coordinator.setAttestationComposeAllowed(COMPOSE_V1, false);
        vm.stopPrank();

        assertFalse(coordinator.isOracle(transmitter));

        AttestationClaim memory v2 = _claim(transmitter2, keccak256("device-2"), COMPOSE_V2, keccak256("n8"));
        coordinator.registerOracle(abi.encode(v2));
        assertTrue(coordinator.isOracle(transmitter2));
    }

    function test_breakglass_policyExempt() public {
        vm.prank(constitutional);
        coordinator.registerOracleBreakglass(DEVICE, transmitter);

        vm.prank(dao);
        coordinator.setAttestationComposeAllowed(COMPOSE_V1, false);

        assertTrue(coordinator.isOracle(transmitter));
        assertEq(coordinator.getRegistration(transmitter).composeHash, bytes32(0));
    }

    function test_breakglass_addCvm_writesDevice() public {
        vm.prank(constitutional);
        coordinator.addCvm(DEVICE, transmitter);

        assertTrue(dstack.allowedDeviceIds(DEVICE));
        assertTrue(coordinator.isOracle(transmitter));
    }

    function test_onlyDao_setRegistrationTtl() public {
        vm.prank(dao);
        coordinator.setRegistrationTtl(2 days);
        assertEq(coordinator.registrationTtl(), 2 days);

        vm.prank(transmitter);
        vm.expectRevert();
        coordinator.setRegistrationTtl(3 days);
    }
}
