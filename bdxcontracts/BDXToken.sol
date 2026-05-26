// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BDXToken
 * @notice $BDX — governance and utility token for Brimdex
 *
 * Supply:
 *   750,000,000 BDX hard cap
 *   210,000,000 BDX allocated to BDXEmissionsVault at deploy; owner may mint the remainder for treasury / liquidity.
 *   Year 1: 75M BDX  (~1,442,308 BDX/week)
 *   Year 2: 55M BDX  (~1,057,692 BDX/week)
 *   Year 3: 45M BDX  (~865,385 BDX/week)
 *   Year 4: 35M BDX  (~673,077 BDX/week)
 *
 * ERC20Votes:
 *   Enables on-chain governance via BDXGovernor
 *   Voting power = BDX balance (self-delegate to activate)
 *
 * Ownership:
 *   Deployer sets owner once; owner may transfer to multisig or emissions contracts.
 *   Only owner can mint — enforces `MAX_SUPPLY`.
 */
contract BDXToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    /// @notice Hard cap: 750,000,000 BDX
    uint256 public constant MAX_SUPPLY = 750_000_000e18;

    constructor(address initialOwner)
        ERC20("Brimdex", "BDX")
        ERC20Permit("Brimdex")
        Ownable(initialOwner)
    {}

    /// @notice Mint BDX — only callable by owner (BDXEmissionsDistributor)
    /// @param to Recipient address
    /// @param amount Amount to mint (18 decimals)
    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "BDX: cap exceeded");
        _mint(to, amount);
    }

    // ── ERC20Votes overrides ──────────────────────────────────────────────────

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
