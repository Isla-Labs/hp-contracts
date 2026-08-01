// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAutomataDcapAttestation
 * @notice Minimal Automata DCAP entrypoint used by HP verifiers.
 * @dev See https://docs.ata.network/tee-overview/tee-verifiers/intel-sgx-tdx-dcap/automata-dcap-attestation
 */
interface IAutomataDcapAttestation {
    enum ZkCoProcessorType {
        None,
        RiscZero,
        Succinct,
        Pico
    }

    function verifyAndAttestOnChain(bytes calldata rawQuote) external returns (bool success, bytes memory output);

    function verifyAndAttestWithZKProof(
        bytes calldata output,
        ZkCoProcessorType zkCoprocessor,
        bytes calldata proofBytes
    ) external payable returns (bool success, bytes memory verifiedOutput);
}
