// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title OrderBookLinkedList
/// @notice Linked list library for managing order queues in the order book
library OrderBookLinkedList {
    struct Order {
        address seller;
        uint256 amount;
    }

    struct Node {
        bytes32 next;
        Order order;
    }

    struct LinkedList {
        uint256 length;
        bytes32 head;
        bytes32 tail;
        mapping(bytes32 => OrderBookLinkedList.Node) nodes;
    }

    function initHead(
        LinkedList storage self,
        address _seller,
        uint256 _amount
    ) public returns (bytes32) {
        Order memory o = Order(_seller, _amount);
        Node memory n = Node(0, o);

        bytes32 id = keccak256(
            abi.encodePacked(_seller, _amount, self.length, block.timestamp, block.prevrandao)
        );

        self.nodes[id] = n;
        self.head = id;
        self.tail = id;
        self.length = 1;

        return id;
    }

    function getNode(LinkedList storage self, bytes32 _id)
        public
        view
        returns (Node memory)
    {
        return self.nodes[_id];
    }

    function getLength(LinkedList storage self) public view returns (uint256) {
        return self.length;
    }

    function addNode(
        LinkedList storage self,
        address _seller,
        uint256 _amount
    ) public returns (bytes32) {
        Order memory o = Order(_seller, _amount);
        Node memory n = Node(0, o);

        bytes32 id = keccak256(
            abi.encodePacked(_seller, _amount, self.length, block.timestamp, block.prevrandao)
        );

        self.nodes[id] = n;
        self.nodes[self.tail].next = id;
        self.tail = id;
        self.length += 1;
        return id;
    }

    function popHead(LinkedList storage self) public returns (bool) {
        bytes32 currHead = self.head;

        self.head = self.nodes[currHead].next;

        delete self.nodes[currHead];
        self.length -= 1;
        return true;
    }

    function deleteNode(LinkedList storage self, bytes32 _id)
        public
        returns (bool)
    {
        if (self.head == _id) {
            require(
                self.nodes[_id].order.seller == msg.sender,
                "Unauthorised to delete this order."
            );
            popHead(self);
            return true;
        }

        bytes32 curr = self.nodes[self.head].next;
        bytes32 prev = self.head;

        for (uint256 i = 1; i < self.length; i++) {
            if (curr == _id) {
                require(
                    self.nodes[_id].order.seller == msg.sender,
                    "Unauthorised to delete this order."
                );
                self.nodes[prev].next = self.nodes[curr].next;
                delete self.nodes[curr];
                self.length -= 1;
                return true;
            }
            prev = curr;
            curr = self.nodes[prev].next;
        }
        revert("Order ID not found.");
    }
}
