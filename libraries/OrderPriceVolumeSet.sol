// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title OrderPriceVolumeSet
/// @notice Library for tracking user orders by order ID, price, and volume
library OrderPriceVolumeSet {
    struct OPVnode {
        bytes32 _orderId;
        uint256 _price;  // Price in USDC (6 decimals)
        uint256 _volume;
    }

    struct OPVset {
        mapping(address => OPVnode[]) _orders;
        mapping(bytes32 => uint256) _indexes;
    }

    function _contains(OPVset storage set, bytes32 orderId)
        internal
        view
        returns (bool)
    {
        return set._indexes[orderId] != 0;
    }

    function _at(
        OPVset storage set,
        address userAddress,
        uint256 index
    ) internal view returns (OPVnode memory) {
        return set._orders[userAddress][index];
    }

    function _add(
        OPVset storage set,
        address userAddress,
        bytes32 orderId,
        uint256 price,
        uint256 volume
    ) internal returns (bool) {
        if (!_contains(set, orderId)) {
            set._orders[userAddress].push(OPVnode(orderId, price, volume));
            set._indexes[orderId] = set._orders[userAddress].length;
            return true;
        } else {
            return false;
        }
    }

    function _remove(
        OPVset storage set,
        address userAddress,
        bytes32 orderId
    ) internal returns (bool) {
        uint256 orderIdIndex = set._indexes[orderId];

        if (orderIdIndex != 0) {
            uint256 toDeleteIndex = orderIdIndex - 1;
            uint256 lastIndex = set._orders[userAddress].length - 1;

            if (lastIndex != toDeleteIndex) {
                OPVnode memory lastOPVnode = set._orders[userAddress][
                    lastIndex
                ];

                set._orders[userAddress][toDeleteIndex] = lastOPVnode;
                set._indexes[lastOPVnode._orderId] = orderIdIndex;
            }

            set._orders[userAddress].pop();
            delete set._indexes[orderId];

            return true;
        } else {
            return false;
        }
    }

    function _addVolume(
        OPVset storage set,
        address userAddress,
        bytes32 orderId,
        uint256 volume
    ) internal returns (bool) {
        uint256 orderIdIndex = set._indexes[orderId];

        if (orderIdIndex != 0) {
            set._orders[userAddress][orderIdIndex - 1]._volume += volume;
            return true;
        } else {
            return false;
        }
    }

    function _subVolume(
        OPVset storage set,
        address userAddress,
        bytes32 orderId,
        uint256 volume
    ) internal returns (bool) {
        uint256 orderIdIndex = set._indexes[orderId];

        if (orderIdIndex != 0) {
            set._orders[userAddress][orderIdIndex - 1]._volume -= volume;
            return true;
        } else {
            return false;
        }
    }
}
