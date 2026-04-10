// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title BrimdexParimutuelToken
/// @notice ERC20 token for BOUND or BREAK positions
/// @dev Mintable and burnable by market contract
contract BrimdexParimutuelToken is ERC20, Ownable {
    constructor(
        string memory name,
        string memory symbol,
        address factoryAddress
    ) ERC20(name, symbol) Ownable(factoryAddress) {}

    /// @notice Mint tokens (only market can call)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn tokens from user
    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != from) {
            _spendAllowance(from, msg.sender, amount);
        }
        _burn(from, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6; // Same as USDC
    }
}
