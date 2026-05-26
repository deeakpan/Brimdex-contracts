// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title sBDX
 * @notice Receipt token minted 1:1 when user stakes $BDX in BDXStaking
 *         Lives in user's wallet — transferable, lockable in VotingEscrow
 *         Burned 1:1 when user withdraws $BDX from BDXStaking
 *
 * Only BDXStaking contract can mint/burn
 */
contract SBDX is ERC20, Ownable {
    address public staking;

    modifier onlyStaking() {
        require(msg.sender == staking, "Only staking contract");
        _;
    }

    constructor() ERC20("Staked BDX", "sBDX") Ownable(msg.sender) {}

    /// @notice Set or rotate the BDXStaking contract (owner only).
    function setStaking(address _staking) external onlyOwner {
        require(_staking != address(0), "zero staking");
        staking = _staking;
    }

    /// @notice Mint sBDX to user when they stake $BDX — called by BDXStaking
    function mint(address to, uint256 amount) external onlyStaking {
        _mint(to, amount);
    }

    /// @notice Burn sBDX from user when they withdraw $BDX — called by BDXStaking
    function burn(address from, uint256 amount) external onlyStaking {
        _burn(from, amount);
    }
}
