// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockTarget {
    uint256 public lastValue;
    bytes public lastData;
    uint256 public callCount;

    event Pinged(uint256 value, bytes data);

    function ping(uint256 note) external payable returns (uint256) {
        lastValue = msg.value;
        lastData = msg.data;
        callCount++;
        emit Pinged(msg.value, msg.data);
        return note;
    }

    function alwaysReverts() external payable {
        revert("MockTarget: always reverts");
    }

    receive() external payable {
        lastValue = msg.value;
        callCount++;
    }
}