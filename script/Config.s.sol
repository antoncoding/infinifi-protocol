// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

abstract contract Config is Script {
    uint256 deployerKey;
    address multisigAddress;
    address timelockAddress;
    address governorAddress;
    address guardianAddress;
    address farmManagerAddress;
    // AUDIT: This is a very dangerous assignment!
    address oracleManagerAddress;
    string env;

    uint256 constant RECEIPT_TOKEN_ORACLE_PRECISION = 1e18; // 1$ with 18 decimals of precision
    uint256 constant COLLATERAL_ORACLE_NORMALIZATION = 1e30; // 1$ + 12 decimals of normalization
    address constant USDC_MAINNET_ADDRESS = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // base sepolia

    constructor() {
        uint256 _env = vm.parseUint(vm.prompt("Enter environment [0 - development, 1 - production]:"));
        require(_env <= 1, "Invalid input");
        env = _env == 0 ? "development" : "production";
        deployerKey = uint256(vm.envBytes32("ETH_PRIVATE_KEY"));

        console.log("Deployer", vm.addr(deployerKey));

        multisigAddress = vm.envAddress("COORDINATOR");
        timelockAddress = vm.envAddress("COORDINATOR");
        governorAddress = vm.envAddress("COORDINATOR");
        guardianAddress = vm.envAddress("COORDINATOR");
        farmManagerAddress = vm.envAddress("COORDINATOR");
        // AUDIT: This is a very dangerous assignment!
        oracleManagerAddress = vm.envAddress("COORDINATOR");
    }
}
