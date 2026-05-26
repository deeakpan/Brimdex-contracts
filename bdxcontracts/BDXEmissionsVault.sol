// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BDXEmissionsVault
 * @notice Holds the 210M BDX allocated for emissions.
 *         Only BDXEmissionsDistributor can pull tokens out via release().
 *         No governance involvement — purely mechanical storage.
 *
 * Setup:
 *   1. Deploy BDXEmissionsVault
 *   2. Mint 210M BDX to this contract (BDXToken.mint(vault, 210_000_000e18))
 *   3. Set distributor: setDistributor(BDXEmissionsDistributor)
 *   4. Transfer ownership to Gnosis Safe (emergency recovery only)
 *
 * Flow:
 *   User calls BDXEmissionsDistributor.claim()
 *   → Distributor calls BDXEmissionsVault.release(user, amount)
 *   → Vault transfers BDX to user
 */
interface IBDXEmissionsDistributor {
    function notifyStart() external;
}

contract BDXEmissionsVault is Ownable {
    using SafeERC20 for IERC20;

    /// @notice The BDX token held in this vault.
    IERC20 public immutable bdx;

    /// @notice The only address permitted to call release() — BDXEmissionsDistributor.
    address public distributor;

    event DistributorSet(address indexed distributor);
    event Released(address indexed to, uint256 amount);

    modifier onlyDistributor() {
        require(msg.sender == distributor, "BDXEmissionsVault: not distributor");
        _;
    }

    constructor(address _bdx, address initialOwner) Ownable(initialOwner) {
        require(_bdx != address(0), "BDXEmissionsVault: zero bdx");
        bdx = IERC20(_bdx);
    }

    /// @notice Set the distributor and start the emission clock.
    ///         Callable once — reverts if already set.
    ///         The vault must hold exactly 210,000,000 BDX before this is called.
    /// @param _distributor Address of BDXEmissionsDistributor.
    function setDistributor(address _distributor) external onlyOwner {
        require(distributor == address(0), "BDXEmissionsVault: already set");
        require(_distributor != address(0), "BDXEmissionsVault: zero address");
        require(
            bdx.balanceOf(address(this)) >= 210_000_000e18,
            "BDXEmissionsVault: must fund 210M BDX first"
        );
        distributor = _distributor;
        emit DistributorSet(_distributor);
        // Start the emission clock in the distributor
        IBDXEmissionsDistributor(_distributor).notifyStart();
    }

    /// @notice Release BDX to a recipient. Called only by BDXEmissionsDistributor.
    /// @param to     Recipient address.
    /// @param amount Amount of BDX to release.
    function release(address to, uint256 amount) external onlyDistributor {
        require(amount > 0, "BDXEmissionsVault: zero amount");
        bdx.safeTransfer(to, amount);
        emit Released(to, amount);
    }

    /// @notice Returns the remaining BDX balance available for emissions.
    function remaining() external view returns (uint256) {
        return bdx.balanceOf(address(this));
    }

    /// @notice Emergency: recover any ERC20 accidentally sent here (not BDX).
    ///         Owner is Gnosis Safe — cannot drain emissions.
    function recoverERC20(address token, uint256 amount) external onlyOwner {
        require(token != address(bdx), "BDXEmissionsVault: cannot recover BDX");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
