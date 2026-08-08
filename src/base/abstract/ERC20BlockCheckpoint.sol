// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

/**
 * @title ERC20BlockCheckpoint
 * @notice Balance / supply history keyed by block number (end-of-block semantics).
 * @dev Checkpoints are written on every mint/burn/transfer. Lookups require `blockNumber < block.number`.
 */
abstract contract ERC20BlockCheckpoint is ERC20 {
    struct Checkpoint {
        uint32 fromBlock;
        uint224 value;
    }

    mapping(address account => Checkpoint[]) private _balanceCheckpoints;
    Checkpoint[] private _totalSupplyCheckpoints;

    error FutureLookup(uint256 blockNumber, uint256 currentBlock);

    function balanceOfAt(address account, uint256 blockNumber) public view returns (uint256) {
        return _lookup(_balanceCheckpoints[account], blockNumber);
    }

    function totalSupplyAt(uint256 blockNumber) public view returns (uint256) {
        return _lookup(_totalSupplyCheckpoints, blockNumber);
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);

        if (from == address(0)) {
            _write(_totalSupplyCheckpoints, totalSupply());
            _write(_balanceCheckpoints[to], balanceOf(to));
        } else if (to == address(0)) {
            _write(_totalSupplyCheckpoints, totalSupply());
            _write(_balanceCheckpoints[from], balanceOf(from));
        } else {
            _write(_balanceCheckpoints[from], balanceOf(from));
            _write(_balanceCheckpoints[to], balanceOf(to));
        }
    }

    function _write(Checkpoint[] storage ckpts, uint256 value) private {
        uint224 v = uint224(value);
        uint32 blockNum = uint32(block.number);
        uint256 len = ckpts.length;
        if (len > 0 && ckpts[len - 1].fromBlock == blockNum) {
            ckpts[len - 1].value = v;
        } else {
            ckpts.push(Checkpoint({ fromBlock: blockNum, value: v }));
        }
    }

    function _lookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint256) {
        if (blockNumber >= block.number) revert FutureLookup(blockNumber, block.number);
        uint256 len = ckpts.length;
        if (len == 0) return 0;

        // Latest checkpoint at or before `blockNumber`.
        if (ckpts[len - 1].fromBlock <= blockNumber) {
            return uint256(ckpts[len - 1].value);
        }
        if (ckpts[0].fromBlock > blockNumber) return 0;

        uint256 low = 0;
        uint256 high = len - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (ckpts[mid].fromBlock <= blockNumber) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return uint256(ckpts[low].value);
    }
}
