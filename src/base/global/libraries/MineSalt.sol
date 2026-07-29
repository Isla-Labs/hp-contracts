// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DopplerDN404 } from "@doppler/src/tokens/DopplerDN404.sol";

import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";

/**
 * @title MineSalt
 * @notice Onchain salt mining for Doppler `DN404Factory` CREATE2 player tokens (`0x22…` vanity).
 * @dev Intended for use inside the deploy tx (e.g. `DopplerLocker` → `Airlock.create`), not during
 *      the eligibility / contest waiting room:
 *        1) Mix public entropy (`prevrandao`, L2 `block.number` / `timestamp`, `playerId`, optional
 *           deploy `nonce`) into a seed — not secret / same-block predictable, but not fixed for the
 *           prior ~24h and unique per market (and per L2 block)
 *        2) Walk `keccak256(seed, i)` until the predicted CREATE2 address has the vanity prefix
 *           and is undeployed (collision bump)
 *        3) Caller passes the salt into `Airlock.create` in the same transaction
 *
 *      CREATE2 formula matches `DN404Factory`:
 *        `new DopplerDN404{ salt }(name, symbol, initialSupply, recipient, owner, baseURI, unit)`
 *      with `recipient = owner = airlock` (Airlock.create convention). Initcode hash therefore
 *      depends on name/symbol/supply/baseURI/unit — mine only after those are known.
 *
 *      Contrast with `PlayerVaultFactory` / `PbrTreasuryFactory`, which mine CreateX CREATE3
 *      salts *offline* under a permissioned caller.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
library MineSalt {
    /// @dev Alphabet for the human-readable seed encoding.
    bytes private constant _OPTIONS = "abcdefghijklmnopqrstuvwxyz1234567890";

    uint256 internal constant SEED_LENGTH = 10;

    /// @notice Target leading byte for player-token addresses.
    uint8 internal constant PLAYER_TOKEN_PREFIX = 0x22;

    /// @notice Default search cap (~expected 256 hits/prefix; headroom for collisions).
    uint256 internal constant DEFAULT_MAX_ATTEMPTS = 4096;

    /**
     * @notice Constructor args for `DopplerDN404` as deployed by `DN404Factory` via Airlock.
     * @dev `recipient` and `owner` are both the Airlock address in `Airlock.create`.
     */
    struct Dn404DeployParams {
        string name;
        string symbol;
        uint256 initialSupply;
        address airlock;
        string baseURI;
        uint256 unit;
    }

    /**
     * @notice Mixes block + market entropy into a single word.
     * @dev On Base, `prevrandao` is L1-origin (~12s); `block.number` / `timestamp` move every L2
     *      block. `playerId` separates markets; `nonce` separates same-block deploys if needed.
     */
    function entropy(bytes32 playerId, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(block.prevrandao, block.number, block.timestamp, playerId, nonce, address(this)));
    }

    /**
     * @notice Builds a 10-character seed from `_OPTIONS` using mixed entropy.
     */
    function randomSeed(bytes32 playerId, uint256 nonce) internal view returns (bytes memory seed) {
        if (playerId == bytes32(0)) revert Errors.ZeroId();

        bytes memory options = _OPTIONS;
        seed = new bytes(SEED_LENGTH);

        uint256 mix = uint256(entropy(playerId, nonce));
        for (uint256 i; i < SEED_LENGTH; ++i) {
            mix = uint256(keccak256(abi.encode(mix, i)));
            seed[i] = options[mix % options.length];
        }
    }

    /// @notice Candidate CREATE2 salt at search index `i` for a given seed.
    function saltAt(bytes memory seed, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode(seed, i));
    }

    /// @notice True when `account` starts with `prefix` (e.g. `0x22`).
    function matchesPrefix(address account, uint8 prefix) internal pure returns (bool) {
        return uint8(uint160(account) >> 152) == prefix;
    }

    /**
     * @notice Initcode hash for `DN404Factory.create` with Airlock as recipient + owner.
     */
    function dn404InitCodeHash(Dn404DeployParams memory p) internal pure returns (bytes32) {
        if (p.airlock == address(0)) revert Errors.ZeroAddress();
        if (p.unit == 0 || p.initialSupply == 0 || p.initialSupply % p.unit != 0) {
            revert Errors.InvalidDN404Unit();
        }

        return keccak256(
            abi.encodePacked(
                type(DopplerDN404).creationCode,
                abi.encode(p.name, p.symbol, p.initialSupply, p.airlock, p.airlock, p.baseURI, p.unit)
            )
        );
    }

    /**
     * @notice Predicted `DopplerDN404` address for `salt` (`tokenFactory` = CREATE2 deployer).
     */
    function predictTokenAddress(
        address tokenFactory,
        bytes32 salt,
        bytes32 initCodeHash_
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), tokenFactory, salt, initCodeHash_)))));
    }

    /**
     * @notice Mine a free vanity salt for a Doppler DN404 player token.
     * @param tokenFactory `DN404Factory` (Airlock TokenFactory module)
     * @param deployParams Constructor args that will be used at `Airlock.create` time
     * @param playerId Market identity mixed into the seed
     * @param nonce Optional deploy counter (0 if unused); bump for same-block uniqueness
     * @param prefix Leading address byte to target (`PLAYER_TOKEN_PREFIX` for production)
     * @param maxAttempts Search bound before `SaltMineExhausted`
     */
    function minePlayerTokenSalt(
        address tokenFactory,
        Dn404DeployParams memory deployParams,
        bytes32 playerId,
        uint256 nonce,
        uint8 prefix,
        uint256 maxAttempts
    ) internal view returns (bytes32 salt, address predicted, bytes memory seed) {
        if (tokenFactory == address(0)) revert Errors.ZeroAddress();
        if (maxAttempts == 0) revert Errors.SaltMineExhausted(0);

        bytes32 initCodeHash_ = dn404InitCodeHash(deployParams);
        seed = randomSeed(playerId, nonce);

        for (uint256 i; i < maxAttempts; ++i) {
            salt = saltAt(seed, i);
            predicted = predictTokenAddress(tokenFactory, salt, initCodeHash_);

            if (!matchesPrefix(predicted, prefix)) continue;
            if (predicted.code.length != 0) continue; // collision bump — already occupied

            return (salt, predicted, seed);
        }

        revert Errors.SaltMineExhausted(maxAttempts);
    }

    /// @notice Convenience: mine `0x22…` with `DEFAULT_MAX_ATTEMPTS`, `nonce = 0`.
    function minePlayerTokenSalt(
        address tokenFactory,
        Dn404DeployParams memory deployParams,
        bytes32 playerId
    ) internal view returns (bytes32 salt, address predicted, bytes memory seed) {
        return minePlayerTokenSalt(tokenFactory, deployParams, playerId, 0, PLAYER_TOKEN_PREFIX, DEFAULT_MAX_ATTEMPTS);
    }

    /// @notice Convenience: mine `0x22…` with `DEFAULT_MAX_ATTEMPTS` and an explicit `nonce`.
    function minePlayerTokenSalt(
        address tokenFactory,
        Dn404DeployParams memory deployParams,
        bytes32 playerId,
        uint256 nonce
    ) internal view returns (bytes32 salt, address predicted, bytes memory seed) {
        return minePlayerTokenSalt(
            tokenFactory, deployParams, playerId, nonce, PLAYER_TOKEN_PREFIX, DEFAULT_MAX_ATTEMPTS
        );
    }
}
