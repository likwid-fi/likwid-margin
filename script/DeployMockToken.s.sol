// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract DeployMockTokenScript is Script {
    MockERC20 tokenA;
    MockERC20 tokenB;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        tokenA = new MockERC20("TESTA", "TESTA", 18);
        console2.log("tokenA", address(tokenA));
        tokenB = new MockERC20("TESTB", "TESTB", 18);
        console2.log("tokenB", address(tokenB));
        vm.stopBroadcast();
    }
}
