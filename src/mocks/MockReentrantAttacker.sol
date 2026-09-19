// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockReentrantAttacker {
    address public immutable payroll;
    bytes public reentryCalldata;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(address _payroll) {
        payroll = _payroll;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    receive() external payable {
        if (reentryCalldata.length > 0) {
            bytes memory data = reentryCalldata;
            reentryCalldata = "";
            reentryAttempted = true;
            (bool success,) = payroll.call(data);
            reentrySucceeded = success;
        }
    }
}