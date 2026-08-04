// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DopplerDN404 } from "@doppler/src/tokens/DopplerDN404.sol";

import { CreateXAddresses } from "@base/global/libraries/addresses/CreateX.sol";
import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";

/**
 * @title MineSalt
 * @notice Onchain vanity-salt mining for same-tx market deploys (`Airlock.create` + vault/treasury).
 * @dev Call from the deploy transaction (e.g. `DopplerLocker.executeDeploy`), not during the
 *      eligibility / queue wait:
 *        1) `seed(id, nonce)` mixes L2 block fields + id + uniqueness counter — public and
 *           same-block simulatable, but not fixed for the prior ~24h queue window
 *        2) Walk candidates until the predicted address has the vanity prefix and is empty
 *        3) Pass salts into create in the **same** transaction (do not emit salts beforehand)
 *
 *      Prefixes (match CVM `VanitySalts` / product convention):
 *        - PlayerToken  `0x22` — `DN404Factory` CREATE2 (initcode-dependent)
 *        - PlayerVault  `0x42` — CreateX CREATE3 via `PlayerVaultFactory` (initcode-independent)
 *        - PbrTreasury  `0x99` — CreateX CREATE3 via `PbrTreasuryFactory` (initcode-independent)
 *
 *      CREATE2 matches `DN404Factory`: `new DopplerDN404{ salt }(..., airlock, airlock, ...)`.
 *      CREATE3 matches factory `makeSalt` + CreateX permissioned guard (`factory || 0x00 || e11`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
library MineSalt {
    /// @notice PlayerToken vanity prefix (`DN404Factory` CREATE2).
    uint8 internal constant PLAYER_TOKEN_PREFIX = 0x22;

    /// @notice PlayerVault vanity prefix (CreateX CREATE3).
    uint8 internal constant PLAYER_VAULT_PREFIX = 0x42;

    /// @notice PbrTreasury vanity prefix (CreateX CREATE3).
    uint8 internal constant PBR_TREASURY_PREFIX = 0x99;

    /// @notice Search cap per salt (~expected 256 hits/prefix; bump `nonce` and retry on exhaust).
    uint256 internal constant DEFAULT_MAX_ATTEMPTS = 1024;

    /// @dev Solady / CreateX CREATE3 proxy initcode hash.
    bytes32 internal constant CREATE3_PROXY_INITCODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

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

    struct AssetSalts {
        bytes32 seed;
        bytes32 tokenSalt;
        address tokenPredicted;
        bytes32 vaultSalt;
        address vaultPredicted;
    }

    // --------------------------------------------
    //  Entropy
    // --------------------------------------------

    /**
     * @notice Block-mixed seed for salt mining / derivation.
     * @dev On Base, `prevrandao` is L1-origin (~12s); `block.number` / `timestamp` move every L2
     *      block. `id` separates markets; `nonce` is a uniqueness / retry counter (not randomness).
     *      `address(this)` binds the seed to the calling deployer contract.
     */
    function seed(bytes32 id, uint256 nonce) internal view returns (bytes32) {
        if (id == bytes32(0)) revert Errors.ZeroId();
        return keccak256(abi.encode(block.prevrandao, block.number, block.timestamp, id, nonce, address(this)));
    }

    /**
     * @notice Single-shot CREATE2 salt (no vanity walk) — cheapest anti-queue-predictability option.
     * @dev `salt == seed(id, nonce)`. Address will not be `0x22…`.
     */
    function deriveTokenSalt(bytes32 id, uint256 nonce) internal view returns (bytes32) {
        return seed(id, nonce);
    }

    // --------------------------------------------
    //  Prefix / CREATE2
    // --------------------------------------------

    /// @notice True when `account` starts with `prefix` (e.g. `0x22`).
    function matchesPrefix(address account, uint8 prefix) internal pure returns (bool) {
        return uint8(uint160(account) >> 152) == prefix;
    }

    /// @notice Candidate CREATE2 salt at search index `i` (matches oracle `create2SaltAt`).
    function create2SaltAt(bytes32 seed_, uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode(seed_, i));
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

    /// @notice Predicted `DopplerDN404` address for `salt` (`tokenFactory` = CREATE2 deployer).
    function predictTokenAddress(
        address tokenFactory,
        bytes32 salt,
        bytes32 initCodeHash_
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), tokenFactory, salt, initCodeHash_)))));
    }

    // --------------------------------------------
    //  CreateX CREATE3 (permissioned factory salts)
    // --------------------------------------------

    /**
     * @notice CreateX salt permissioned to `factory`: `factory || 0x00 || entropy11`.
     * @dev Byte 21 `0x00` = permissioned deploy, no cross-chain redeploy guard. Matches factory `makeSalt`.
     */
    function makePermissionedSalt(address factory, uint88 entropy) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(factory))) << 96 | bytes32(uint256(entropy));
    }

    /// @notice CreateX guarded salt when `msg.sender == factory` and flag `0x00`.
    function computeGuardedSalt(address factory, bytes32 salt) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, factory)
            mstore(0x20, salt)
            hash := keccak256(0x00, 0x40)
        }
    }

    /**
     * @notice CreateX CREATE3 address for a guarded salt (Solady formula).
     * @dev Proxy = CREATE2(CreateX, guardedSalt, PROXY_INITCODE_HASH); final = CREATE(proxy, nonce=1).
     */
    function predictCreate3Address(bytes32 guardedSalt) internal pure returns (address) {
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), CreateXAddresses.CREATE_X, guardedSalt, CREATE3_PROXY_INITCODE_HASH
                        )
                    )
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxy, bytes1(0x01))))));
    }

    /// @notice Predicted CREATE3 address when `factory` deploys with permissioned `salt`.
    function predictCreate3FactoryAddress(address factory, bytes32 salt) internal pure returns (address) {
        return predictCreate3Address(computeGuardedSalt(factory, salt));
    }

    // --------------------------------------------
    //  Mine — PlayerToken `0x22`
    // --------------------------------------------

    /**
     * @notice Mine a free `0x22…` CREATE2 salt from an existing `seed_`.
     */
    function minePlayerTokenSalt(
        address tokenFactory,
        bytes32 initCodeHash_,
        bytes32 seed_,
        uint8 prefix,
        uint256 maxAttempts
    ) internal view returns (bytes32 salt, address predicted) {
        if (tokenFactory == address(0)) revert Errors.ZeroAddress();
        if (initCodeHash_ == bytes32(0)) revert Errors.ZeroId();
        if (maxAttempts == 0) revert Errors.SaltMineExhausted(0);

        for (uint256 i; i < maxAttempts; ++i) {
            salt = create2SaltAt(seed_, i);
            predicted = predictTokenAddress(tokenFactory, salt, initCodeHash_);

            if (!matchesPrefix(predicted, prefix)) continue;
            if (predicted.code.length != 0) continue;

            return (salt, predicted);
        }

        revert Errors.SaltMineExhausted(maxAttempts);
    }

    function minePlayerTokenSalt(
        address tokenFactory,
        bytes32 initCodeHash_,
        bytes32 seed_
    ) internal view returns (bytes32 salt, address predicted) {
        return minePlayerTokenSalt(
            tokenFactory, initCodeHash_, seed_, PLAYER_TOKEN_PREFIX, DEFAULT_MAX_ATTEMPTS
        );
    }

    function minePlayerTokenSalt(
        address tokenFactory,
        Dn404DeployParams memory deployParams,
        bytes32 id,
        uint256 nonce
    ) internal view returns (bytes32 salt, address predicted) {
        return minePlayerTokenSalt(tokenFactory, dn404InitCodeHash(deployParams), seed(id, nonce));
    }

    // --------------------------------------------
    //  Mine — CREATE3 `0x42` / `0x99`
    // --------------------------------------------

    /**
     * @notice Mine a free CreateX CREATE3 vanity salt for `factory`.
     * @param domain Domain string mixed into the entropy start (`"vault"` / `"treasury"`) — matches oracle.
     */
    function mineCreate3VanitySalt(
        address factory,
        bytes32 seed_,
        string memory domain,
        uint8 prefix,
        uint256 maxAttempts
    ) internal view returns (bytes32 salt, address predicted) {
        if (factory == address(0)) revert Errors.ZeroAddress();
        if (maxAttempts == 0) revert Errors.SaltMineExhausted(0);

        uint88 start = uint88(uint256(keccak256(abi.encode(seed_, domain))));

        for (uint256 i; i < maxAttempts; ++i) {
            uint88 entropy;
            unchecked {
                entropy = start + uint88(i); // wrap like oracle `mineCreate3VanitySalt`
            }
            salt = makePermissionedSalt(factory, entropy);
            predicted = predictCreate3FactoryAddress(factory, salt);

            if (!matchesPrefix(predicted, prefix)) continue;
            if (predicted.code.length != 0) continue;

            return (salt, predicted);
        }

        revert Errors.SaltMineExhausted(maxAttempts);
    }

    function minePlayerVaultSalt(
        address vaultFactory,
        bytes32 seed_
    ) internal view returns (bytes32 salt, address predicted) {
        return mineCreate3VanitySalt(
            vaultFactory, seed_, "vault", PLAYER_VAULT_PREFIX, DEFAULT_MAX_ATTEMPTS
        );
    }

    function minePbrTreasurySalt(
        address treasuryFactory,
        bytes32 seed_
    ) internal view returns (bytes32 salt, address predicted) {
        return mineCreate3VanitySalt(
            treasuryFactory, seed_, "treasury", PBR_TREASURY_PREFIX, DEFAULT_MAX_ATTEMPTS
        );
    }

    function minePbrTreasurySalt(
        address treasuryFactory,
        bytes32 tournamentId,
        uint256 nonce
    ) internal view returns (bytes32 salt, address predicted) {
        return minePbrTreasurySalt(treasuryFactory, seed(tournamentId, nonce));
    }

    // --------------------------------------------
    //  Mine — Asset pair (`0x22` + `0x42`)
    // --------------------------------------------

    /**
     * @notice Mine PlayerToken + PlayerVault salts from one block-mixed seed (same-tx deploy path).
     */
    function mineAssetSalts(
        address tokenFactory,
        bytes32 tokenInitCodeHash,
        address vaultFactory,
        bytes32 playerId,
        uint256 nonce
    ) internal view returns (AssetSalts memory result) {
        result.seed = seed(playerId, nonce);
        (result.tokenSalt, result.tokenPredicted) =
            minePlayerTokenSalt(tokenFactory, tokenInitCodeHash, result.seed);
        (result.vaultSalt, result.vaultPredicted) = minePlayerVaultSalt(vaultFactory, result.seed);
    }

    function mineAssetSalts(
        address tokenFactory,
        Dn404DeployParams memory deployParams,
        address vaultFactory,
        bytes32 playerId,
        uint256 nonce
    ) internal view returns (AssetSalts memory result) {
        return mineAssetSalts(
            tokenFactory, dn404InitCodeHash(deployParams), vaultFactory, playerId, nonce
        );
    }
}
