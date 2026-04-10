// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDataStreams
/// @notice Interface for Somnia Data Streams contract
interface IDataStreams {
    struct DataStream {
        bytes32 id;
        bytes32 schemaId;
        bytes data;
    }

    /// @notice Store data streams on-chain
    /// @param streams Array of data streams to store
    function esstores(DataStream[] calldata streams) external;
}
