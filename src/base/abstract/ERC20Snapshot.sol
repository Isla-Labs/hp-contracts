// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @title ERC20Snapshot
 * @notice Local, v5-compatible ERC20Snapshot. Based on OZ v4.x semantics, adapted to _update hook.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
abstract contract ERC20Snapshot is ERC20 {
    // Forked version of the original OpenZeppelin ERC20Snapshot contract that was deprecated in v5:
    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/a70ee4e3bbee565e49217c9ec59de5354f8af9d8/contracts/token/ERC20/extensions/ERC20Snapshot.sol

    struct Snapshots {
        uint256[] ids;
        uint256[] values;
    }

    mapping(address => Snapshots) private _accountBalanceSnapshots;
    Snapshots private _totalSupplySnapshots;

    // Snapshot ids increase monotonically, starting at 1. 0 is invalid.
    uint256 private _currentSnapshotId;

    event Snapshot(uint256 id);

    /**
     * @dev Creates a new snapshot and returns its id.
     */
    function _snapshot() internal virtual returns (uint256) {
        unchecked {
            _currentSnapshotId += 1;
        }
        uint256 currentId = _getCurrentSnapshotId();
        emit Snapshot(currentId);
        return currentId;
    }

    /**
     * @dev Get the current snapshot id.
     */
    function _getCurrentSnapshotId() internal view virtual returns (uint256) {
        return _currentSnapshotId;
    }

    /**
     * @dev Retrieves the balance of `account` at the time `snapshotId` was created.
     */
    function balanceOfAt(address account, uint256 snapshotId) public view virtual returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _accountBalanceSnapshots[account]);
        return snapshotted ? value : balanceOf(account);
    }

    /**
     * @dev Retrieves the total supply at the time `snapshotId` was created.
     */
    function totalSupplyAt(uint256 snapshotId) public view virtual returns (uint256) {
        (bool snapshotted, uint256 value) = _valueAt(snapshotId, _totalSupplySnapshots);
        return snapshotted ? value : totalSupply();
    }

    /**
     * @dev Update snapshots before balances/supply are modified.
     * Adapts OZ v4 Snapshot logic to v5 `_update` hook.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0)) {
            // mint
            _updateAccountSnapshot(to);
            _updateTotalSupplySnapshot();
        } else if (to == address(0)) {
            // burn
            _updateAccountSnapshot(from);
            _updateTotalSupplySnapshot();
        } else {
            // transfer
            _updateAccountSnapshot(from);
            _updateAccountSnapshot(to);
        }
        super._update(from, to, value);
    }

    function _valueAt(uint256 snapshotId, Snapshots storage snapshots) private view returns (bool, uint256) {
        require(snapshotId > 0, "ERC20Snapshot: id is 0");
        require(snapshotId <= _getCurrentSnapshotId(), "ERC20Snapshot: nonexistent id");

        uint256 index = _findUpperBound(snapshots.ids, snapshotId);

        if (index == snapshots.ids.length) {
            return (false, 0);
        } else {
            return (true, snapshots.values[index]);
        }
    }

    function _updateAccountSnapshot(address account) private {
        _updateSnapshot(_accountBalanceSnapshots[account], balanceOf(account));
    }

    function _updateTotalSupplySnapshot() private {
        _updateSnapshot(_totalSupplySnapshots, totalSupply());
    }

    function _updateSnapshot(Snapshots storage snapshots, uint256 currentValue) private {
        uint256 currentId = _getCurrentSnapshotId();
        if (_lastSnapshotId(snapshots.ids) < currentId) {
            snapshots.ids.push(currentId);
            snapshots.values.push(currentValue);
        }
    }

    function _lastSnapshotId(uint256[] storage ids) private view returns (uint256) {
        if (ids.length == 0) {
            return 0;
        } else {
            return ids[ids.length - 1];
        }
    }

    // Returns OZ-compatible upper bound:
    // - If an exact match exists, returns its index.
    // - Otherwise, returns index of first element greater than `element` (or length if none).
    function _findUpperBound(uint256[] storage array, uint256 element) private view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (array[mid] > element) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        if (low > 0 && array[low - 1] == element) {
            return low - 1;
        } else {
            return low;
        }
    }
}
