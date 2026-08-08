// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Accepts all ETH transfers.
contract AcceptingReceiver {
    receive() external payable { }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}

/// @notice Always reverts on ETH receive (soft-queue / pending paths).
contract RevertingReceiver {
    receive() external payable {
        revert("reject");
    }
}

/// @notice Toggleable ETH sink for pending retry tests.
contract ToggleReceiver {
    bool public accept = true;

    function setAccept(bool accept_) external {
        accept = accept_;
    }

    receive() external payable {
        if (!accept) revert("reject");
    }
}

/// @notice Minimal ERC20 for `FeeRouter.rescueToken`.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
