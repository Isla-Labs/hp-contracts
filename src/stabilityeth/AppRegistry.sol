// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { MinterFactory } from "@stabilityeth/factories/MinterFactory.sol";
import { SETH } from "@stabilityeth/SETH.sol";

/**
 * @title AppRegistry
 * @notice Registers dApps for SETH PBR: verified TVL targets, beneficiaries, and per-app Minter.
 * @dev Owner finalizes verification → allocates `appId`, deploys Minter, binds TVL.
 *      `rootDeployer` may set yield beneficiaries (share-split). Any beneficiary may claim via Minter.
 *      See `verificationPlan.md`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract AppRegistry is Ownable {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct Beneficiary {
        address account;
        uint16 shareBps;
    }

    struct App {
        address rootDeployer;
        address minter;
        address[] tvlContracts;
        Beneficiary[] beneficiaries;
        bool active;
    }

    SETH public immutable seth;
    MinterFactory public immutable minterFactory;

    /// @notice SETH PBR treasury used by minters for yield claims
    address public pbrTreasury;

    uint256 private _appIdNonce;

    mapping(bytes32 appId => App) private _apps;
    mapping(bytes32 appId => mapping(address account => uint16 shareBps)) public beneficiaryShareBps;
    mapping(address tvlContract => bytes32 appId) public appIdOfContract;
    mapping(address minter => bytes32 appId) public appIdOfMinter;

    /// @notice Cumulative SETH minted through each app's minter (CRE samples for TW mint-delta)
    mapping(bytes32 appId => uint256) public totalMinted;

    /// @notice Minter-path outstanding supply: +mint / −burn via that app's minter
    mapping(bytes32 appId => uint256) public netMinted;

    bytes32[] private _appIds;

    event AppRegistered(
        bytes32 indexed appId,
        address indexed rootDeployer,
        address indexed minter,
        address[] tvlContracts
    );
    event TvlContractsAdded(bytes32 indexed appId, address[] tvlContracts);
    event TvlContractRemoved(bytes32 indexed appId, address indexed tvlContract);
    event AppActiveUpdated(bytes32 indexed appId, bool active);
    event BeneficiariesUpdated(bytes32 indexed appId, Beneficiary[] beneficiaries);
    event PbrTreasuryUpdated(address indexed pbrTreasury);
    event MintRecorded(bytes32 indexed appId, uint256 amount, uint256 totalMinted_, uint256 netMinted_);
    event BurnRecorded(bytes32 indexed appId, uint256 amount, uint256 totalMinted_, uint256 netMinted_);

    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error EmptyTvlContracts();
    error NotContract();
    error ContractAlreadyRegistered(address tvlContract);
    error ContractNotRegistered(address tvlContract);
    error NotRootDeployer();
    error EmptyBeneficiaries();
    error InvalidShareBps();
    error DuplicateBeneficiary(address account);
    error NotAppMinter();
    error InvalidAmount();

    modifier onlyRootDeployer(
        bytes32 appId
    ) {
        if (_apps[appId].rootDeployer != msg.sender) revert NotRootDeployer();
        _;
    }

    constructor(address seth_, address minterFactory_, address owner_) Ownable(owner_) {
        if (seth_ == address(0) || minterFactory_ == address(0)) revert ZeroAddress();
        seth = SETH(payable(seth_));
        minterFactory = MinterFactory(minterFactory_);
    }

    /**
     * @notice Finalize verification: create `appId`, bind TVL, deploy Minter, seed rootDeployer as sole beneficiary.
     * @dev `onlyOwner` — DAO / permissioned verifier. Does not mutate verification-critical state via deployer.
     * @param rootDeployer Verified root deployer (or factory-as-app).
     * @param tvlContracts Contracts CRE should include in this app's TVL.
     * @return appId Canonical app identity for Minter / claims / TVL.
     * @return minter Newly deployed Minter proxy.
     */
    function register(
        address rootDeployer,
        address[] calldata tvlContracts
    ) external onlyOwner returns (bytes32 appId, address minter) {
        if (rootDeployer == address(0)) revert ZeroAddress();
        if (tvlContracts.length == 0) revert EmptyTvlContracts();

        appId = keccak256(abi.encode(rootDeployer, tvlContracts, ++_appIdNonce, block.chainid, address(this)));
        if (_apps[appId].rootDeployer != address(0)) revert AlreadyRegistered();

        minter = minterFactory.create(appId);
        seth.setMinter(minter, true);

        App storage row = _apps[appId];
        row.rootDeployer = rootDeployer;
        row.minter = minter;
        row.active = true;
        _appIds.push(appId);
        appIdOfMinter[minter] = appId;

        _addTvlContracts(appId, tvlContracts);

        Beneficiary[] memory initial = new Beneficiary[](1);
        initial[0] = Beneficiary({ account: rootDeployer, shareBps: uint16(BPS_DENOMINATOR) });
        _setBeneficiaries(appId, initial);

        emit AppRegistered(appId, rootDeployer, minter, tvlContracts);
    }

    /**
     * @notice Replace the beneficiary set for `appId`. Shares must sum to 10_000 bps.
     * @dev Only `rootDeployer`. Beneficiaries may claim yield via the app Minter; they cannot edit TVL.
     */
    function setBeneficiaries(
        bytes32 appId,
        Beneficiary[] calldata beneficiaries
    ) external onlyRootDeployer(appId) {
        if (_apps[appId].rootDeployer == address(0)) revert NotRegistered();
        _setBeneficiaries(appId, beneficiaries);
        emit BeneficiariesUpdated(appId, beneficiaries);
    }

    /**
     * @notice Add more verified TVL contracts for `appId`.
     */
    function addTvlContracts(bytes32 appId, address[] calldata tvlContracts) external onlyOwner {
        if (_apps[appId].rootDeployer == address(0)) revert NotRegistered();
        if (tvlContracts.length == 0) revert EmptyTvlContracts();

        _addTvlContracts(appId, tvlContracts);
        emit TvlContractsAdded(appId, tvlContracts);
    }

    /**
     * @notice Remove a TVL contract from `appId`.
     */
    function removeTvlContract(bytes32 appId, address tvlContract) external onlyOwner {
        App storage row = _apps[appId];
        if (row.rootDeployer == address(0)) revert NotRegistered();
        if (appIdOfContract[tvlContract] != appId) revert ContractNotRegistered(tvlContract);

        delete appIdOfContract[tvlContract];

        address[] storage list = row.tvlContracts;
        uint256 len = list.length;
        for (uint256 i; i < len; ++i) {
            if (list[i] == tvlContract) {
                list[i] = list[len - 1];
                list.pop();
                break;
            }
        }

        emit TvlContractRemoved(appId, tvlContract);
    }

    /**
     * @notice Owner kill-switch for an app's PBR eligibility (minter remains usable for wrap UX).
     */
    function setAppActive(bytes32 appId, bool active) external onlyOwner {
        if (_apps[appId].rootDeployer == address(0)) revert NotRegistered();
        _apps[appId].active = active;
        emit AppActiveUpdated(appId, active);
    }

    /// @notice Bind the SETH `PBRTreasury` used for beneficiary claims.
    function setPbrTreasury(
        address pbrTreasury_
    ) external onlyOwner {
        if (pbrTreasury_ == address(0)) revert ZeroAddress();
        pbrTreasury = pbrTreasury_;
        emit PbrTreasuryUpdated(pbrTreasury_);
    }

    // --------------------------------------------
    //  Minter accounting (CRE + PBR eligibility)
    // --------------------------------------------

    /**
     * @notice Credit mint volume for `msg.sender`'s app. Only the app's allowlisted Minter.
     * @dev Increments `totalMinted` (cumulative) and `netMinted` (outstanding).
     */
    function recordMint(
        uint256 sethAmount
    ) external {
        if (sethAmount == 0) revert InvalidAmount();
        bytes32 appId = appIdOfMinter[msg.sender];
        if (appId == bytes32(0)) revert NotAppMinter();

        totalMinted[appId] += sethAmount;
        netMinted[appId] += sethAmount;

        emit MintRecorded(appId, sethAmount, totalMinted[appId], netMinted[appId]);
    }

    /**
     * @notice Debit outstanding mint credit for `msg.sender`'s app. Only the app's Minter.
     * @dev Decreases `netMinted` only (floors at 0). `totalMinted` is never reduced.
     */
    function recordBurn(
        uint256 sethAmount
    ) external {
        if (sethAmount == 0) revert InvalidAmount();
        bytes32 appId = appIdOfMinter[msg.sender];
        if (appId == bytes32(0)) revert NotAppMinter();

        uint256 net = netMinted[appId];
        uint256 debit = sethAmount > net ? net : sethAmount;
        netMinted[appId] = net - debit;

        emit BurnRecorded(appId, debit, totalMinted[appId], netMinted[appId]);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getApp(
        bytes32 appId
    )
        external
        view
        returns (
            address rootDeployer,
            address minter,
            bool active,
            address[] memory tvlContracts,
            Beneficiary[] memory beneficiaries
        )
    {
        App storage row = _apps[appId];
        return (row.rootDeployer, row.minter, row.active, row.tvlContracts, row.beneficiaries);
    }

    function minterOf(
        bytes32 appId
    ) external view returns (address) {
        return _apps[appId].minter;
    }

    function rootDeployerOf(
        bytes32 appId
    ) external view returns (address) {
        return _apps[appId].rootDeployer;
    }

    function isRegistered(
        bytes32 appId
    ) external view returns (bool) {
        return _apps[appId].rootDeployer != address(0);
    }

    function isActive(
        bytes32 appId
    ) external view returns (bool) {
        return _apps[appId].active;
    }

    function isBeneficiary(bytes32 appId, address account) external view returns (bool) {
        return beneficiaryShareBps[appId][account] != 0;
    }

    function appCount() external view returns (uint256) {
        return _appIds.length;
    }

    function appIdAt(
        uint256 index
    ) external view returns (bytes32) {
        return _appIds[index];
    }

    function tvlContractsOf(
        bytes32 appId
    ) external view returns (address[] memory) {
        return _apps[appId].tvlContracts;
    }

    function beneficiariesOf(
        bytes32 appId
    ) external view returns (Beneficiary[] memory) {
        return _apps[appId].beneficiaries;
    }

    /**
     * @notice CRE helper: mint stats for one app.
     * @return total Cumulative SETH minted through the app minter.
     * @return net Outstanding SETH attributed to the app minter (`netMinted`).
     * @return minter App minter address.
     * @return active Whether the app is PBR-active.
     */
    function getMintStats(
        bytes32 appId
    ) external view returns (uint256 total, uint256 net, address minter, bool active) {
        App storage row = _apps[appId];
        return (totalMinted[appId], netMinted[appId], row.minter, row.active);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _addTvlContracts(bytes32 appId, address[] calldata tvlContracts) internal {
        App storage row = _apps[appId];

        for (uint256 i; i < tvlContracts.length; ++i) {
            address tvl = tvlContracts[i];
            if (tvl == address(0)) revert ZeroAddress();
            if (tvl.code.length == 0) revert NotContract();
            if (appIdOfContract[tvl] != bytes32(0)) revert ContractAlreadyRegistered(tvl);

            appIdOfContract[tvl] = appId;
            row.tvlContracts.push(tvl);
        }
    }

    function _setBeneficiaries(bytes32 appId, Beneficiary[] memory beneficiaries) internal {
        if (beneficiaries.length == 0) revert EmptyBeneficiaries();

        App storage row = _apps[appId];

        // Clear previous share index + list
        uint256 prevLen = row.beneficiaries.length;
        for (uint256 i; i < prevLen; ++i) {
            delete beneficiaryShareBps[appId][row.beneficiaries[i].account];
        }
        delete row.beneficiaries;

        uint256 totalBps;
        for (uint256 i; i < beneficiaries.length; ++i) {
            address account = beneficiaries[i].account;
            uint16 shareBps = beneficiaries[i].shareBps;

            if (account == address(0)) revert ZeroAddress();
            if (shareBps == 0) revert InvalidShareBps();
            if (beneficiaryShareBps[appId][account] != 0) revert DuplicateBeneficiary(account);

            beneficiaryShareBps[appId][account] = shareBps;
            row.beneficiaries.push(Beneficiary({ account: account, shareBps: shareBps }));
            totalBps += shareBps;
        }

        if (totalBps != BPS_DENOMINATOR) revert InvalidShareBps();
    }
}
