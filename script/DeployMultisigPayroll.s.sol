// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MultisigPayroll} from "../src/MultisigPayroll.sol";

/// @dev Configure via env vars before running:
///        OWNERS      comma-separated owner addresses
///        THRESHOLD   required signature quorum
///        PRIVATE_KEY deployer key (funds gas only)
contract DeployMultisigPayroll is Script {
    function run() external returns (MultisigPayroll payroll) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address[] memory owners = vm.envAddress("OWNERS", ",");
        uint256 threshold = vm.envUint("THRESHOLD");

        vm.startBroadcast(deployerKey);
        payroll = new MultisigPayroll(owners, threshold);
        vm.stopBroadcast();

        console2.log("MultisigPayroll deployed at:", address(payroll));
        console2.log("Threshold:", threshold);
        console2.log("Owner count:", owners.length);
        for (uint256 i = 0; i < owners.length; i++) {
            console2.log("  owner:", owners[i]);
        }
    }
}