// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BDXTreasury
 * @notice Protocol treasury — holds whatever it is funded with.
 *         Owned by TimelockController (BDXGovernor).
 *         Governance votes to move funds out.
 *
 * What it holds:
 *   Whatever the team/community sends to it — BDX, USDC, ETH, anything.
 *   It does NOT automatically receive protocol fees (those go to protocolWallet).
 *   It is funded manually/intentionally.
 *
 * What governance can do:
 *   - transferERC20(token, to, amount) — move any ERC20 out
 *   - transferETH(to, amount)          — move ETH out
 *   - execute(target, value, data)     — arbitrary call (for complex operations)
 *
 * Ownership:
 *   owner = TimelockController (controlled by BDXGovernor / xBDX vote)
 *   No multisig involvement — purely community governed
 */
contract BDXTreasury is Ownable {
    using SafeERC20 for IERC20;

    event ERC20Transferred(address indexed token, address indexed to, uint256 amount);
    event ETHTransferred(address indexed to, uint256 amount);
    event Executed(address indexed target, uint256 value, bytes data);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Accept ETH deposits.
    receive() external payable {}

    // ── Governance-controlled transfers ───────────────────────────────────────

    /// @notice Transfer ERC20 tokens from the treasury.
    ///         Called by TimelockController after a successful governance vote.
    /// @param token  ERC20 token address.
    /// @param to     Recipient address.
    /// @param amount Amount to transfer.
    function transferERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "BDXTreasury: zero recipient");
        require(amount > 0, "BDXTreasury: zero amount");
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Transferred(token, to, amount);
    }

    /// @notice Transfer ETH from the treasury.
    ///         Called by TimelockController after a successful governance vote.
    /// @param to     Recipient address.
    /// @param amount Amount in wei.
    function transferETH(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "BDXTreasury: zero recipient");
        require(amount > 0, "BDXTreasury: zero amount");
        require(address(this).balance >= amount, "BDXTreasury: insufficient ETH");
        (bool success, ) = to.call{value: amount}("");
        require(success, "BDXTreasury: ETH transfer failed");
        emit ETHTransferred(to, amount);
    }

    /// @notice Execute an arbitrary call from the treasury.
    ///         For complex operations like approving a contract to spend treasury funds.
    ///         Called by TimelockController after a successful governance vote.
    /// @param target Contract to call.
    /// @param value  ETH to send with the call.
    /// @param data   Calldata.
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bytes memory result)
    {
        require(target != address(0), "BDXTreasury: zero target");
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        require(success, "BDXTreasury: execution failed");
        emit Executed(target, value, data);
        return returnData;
    }

    /// @notice Returns ETH balance of the treasury.
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns ERC20 balance of the treasury.
    function erc20Balance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
