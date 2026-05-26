// SPDX-License-Identifier: LGPL-3.0
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Whitelist (Gnosis fork, OZ Ownable)
contract Whitelist is Ownable {
    event UsersAddedToWhitelist(address[] users);
    event UsersRemovedFromWhitelist(address[] users);

    mapping(address => bool) public isWhitelisted;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function addToWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = true;
        }
        emit UsersAddedToWhitelist(users);
    }

    function removeFromWhitelist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = false;
        }
        emit UsersRemovedFromWhitelist(users);
    }
}
