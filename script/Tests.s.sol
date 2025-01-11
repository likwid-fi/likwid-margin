// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {MarginOracle} from "../src/MarginOracle.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";
import {MarginHookManager} from "../src/MarginHookManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

interface IMarginPositionManager {
    function margin(MarginParams memory params) external payable returns (uint256, uint256);
    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position);
    function estimatePNL(uint256 positionId, uint256 repayMillionth) external view returns (int256 pnlMinAmount);
}

contract TestsScript is Script {
    address marginLiquidity = 0xDD0AebD45cd5c339e366fB7DEF71143C78585a6f;
    address hookAddress = 0x41e1C0cd59d538893dF9960373330585Dc3e8888;
    address marginPositionManager = 0xd28800A45EF2650CF2b3CDd0bF1b75bd4b9c9D92;
    address pepe = 0x692CA9D3078Aa6b54F2F0e33Ed20D30489854A21;
    address user = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        // IERC20Minimal(pepe).approve(pepe, 100 ether);
        // IERC20Minimal(pepe).approve(address(this), 100 ether);
        // IERC20Minimal(pepe).approve(marginPositionManager, 100 ether);
        // // MarginLiquidity(marginLiquidity).addHooks(hookAddress);
        // // MarginHookManager(hookAddress).setFeeStatus()
        // bytes32 poolId = 0x52c4648f1db7040bdf0c13c4c7bdedf9a2edf4a1e6dfd899b06ff7f877794fb3;
        // MarginParams memory params = MarginParams({
        //     poolId: PoolId.wrap(poolId),
        //     marginForOne: true,
        //     leverage: 1,
        //     marginAmount: 100 ether,
        //     marginTotal: 0,
        //     borrowAmount: 0,
        //     borrowMinAmount: 0,
        //     recipient: user,
        //     deadline: block.timestamp + 1000
        // });
        // (uint256 positionId, uint256 borrowAmount) = IMarginPositionManager(marginPositionManager).margin(params);
        // console2.log("positionId", positionId);
        // console2.log("borrowAmount", borrowAmount);
        int256 pnlMinAmount = IMarginPositionManager(marginPositionManager).estimatePNL(4, 1000000);
        console2.log("pnlMinAmount", pnlMinAmount);
        MarginPosition memory _position = IMarginPositionManager(marginPositionManager).getPosition(4);
        console2.log("position", _position.marginAmount + _position.marginTotal);
        vm.stopBroadcast();
    }
}
