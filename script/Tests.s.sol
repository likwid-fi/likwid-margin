// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencyExtLibrary} from "../src/libraries/CurrencyExtLibrary.sol";
import {CurrencyPoolLibrary} from "../src/libraries/CurrencyPoolLibrary.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {MarginParams} from "../src/types/MarginParams.sol";
import {MarginPosition} from "../src/types/MarginPosition.sol";
import {MarginOracle} from "../src/MarginOracle.sol";
import {MarginLiquidity} from "../src/MarginLiquidity.sol";
import {PairPoolManager} from "../src/PairPoolManager.sol";
import {MarginChecker} from "../src/MarginChecker.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

interface IMarginPositionManager {
    function getHook() external view returns (address _hook);
    function margin(MarginParams memory params) external payable returns (uint256, uint256);
    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position);
    function estimatePNL(uint256 positionId, uint256 closeMillionth) external view returns (int256 pnlMinAmount);
    function setMarginChecker(address _checker) external;
}

interface IMarginChecker {
    function getBorrowMax(address poolManager, PoolId poolId, bool marginForOne, uint256 marginAmount)
        external
        view
        returns (uint256 marginAmountIn, uint256 borrowAmount);
}

interface IPoolStatusManager {
    function setMarginOracle(address _oracle) external;
    function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
    function balanceOriginal(address owner, uint256 id) external view returns (uint256 amount);
}

interface IMarginLiquidity {
    function getMarginReserves(address pairPoolManager, PoolId poolId)
        external
        view
        returns (
            uint256 marginReserve0,
            uint256 marginReserve1,
            uint256 incrementMaxMirror0,
            uint256 incrementMaxMirror1
        );

    function getMarginMax(address _poolManager, PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount);
}

contract TestsScript is Script {
    using PriceMath for uint224;
    using CurrencyExtLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    // address marginLiquidity = 0xDD0AebD45cd5c339e366fB7DEF71143C78585a6f;
    // address hookAddress = 0x41e1C0cd59d538893dF9960373330585Dc3e8888;
    // address pepe = 0x692CA9D3078Aa6b54F2F0e33Ed20D30489854A21;

    address user = 0x35D3F3497eC612b3Dd982819F95cA98e6a404Ce1;
    address marginPositionManager = 0x913B98B271889D3fB4D375C181FC2E58f17EC6C5;
    // address marginChecker = 0x33657d1629913DeD856A7f0040dA1159Aa06f47d;

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
        // int256 pnlMinAmount = IMarginPositionManager(marginPositionManager).estimatePNL(4, 1000000);
        // console2.log("pnlMinAmount", pnlMinAmount);
        // MarginPosition memory _position = IMarginPositionManager(marginPositionManager).getPosition(4);
        // console2.log("position", _position.marginAmount + _position.marginTotal);
        // PoolId poolId = PoolId.wrap(0x52c4648f1db7040bdf0c13c4c7bdedf9a2edf4a1e6dfd899b06ff7f877794fb3);
        // address hookAddress = IMarginPositionManager(marginPositionManager).getHook();
        // console2.log("hookAddress", hookAddress);
        // (uint256 _reserve0, uint256 _reserve1) = PairPoolManager(hookAddress).getReserves(poolId);
        // console2.log("reserves", _reserve0, _reserve1);
        // address marginOracle = PairPoolManager(hookAddress).statusManager().marginOracle();
        // (uint224 reserves,) = MarginOracle(marginOracle).observeNow(PairPoolManager(hookAddress), poolId);
        // console2.log("reserves", marginOracle, reserves.getReverse0(), reserves.getReverse1());
        // bytes32 poolId = 0x494ce156181fe01988446d1879ddcdd2e5f665f73e86fd6c7d6c3c6731c6441b;
        // (uint256 marginAmountIn, uint256 borrowAmount) = IMarginChecker(marginChecker).getBorrowMax(
        //     0xd2f3f130690fcDB779a778C0fDB28FE13Ef34914, PoolId.wrap(poolId), true, 10000000000000000000
        // );
        // console.log(marginAmountIn, borrowAmount);
        // MarginOracle marginOracle = new MarginOracle();
        // IPoolStatusManager(0x91885403Db4cf2A8b82b46B36905Ba2C11043d1c).setMarginOracle(address(marginOracle));
        // vm.stopBroadcast();
        PoolId poolId = PoolId.wrap(0xaf8d51d259e5aa3f8898acbe5b21ce929b3007167209c8ae5b08f31e7f12d5ef);
        // (,, uint256 incrementMaxMirror0, uint256 incrementMaxMirror1) = IMarginLiquidity(
        //     0x5a3C43798c7D2082a95d8190F4239EC51d90444f
        // ).getMarginReserves(0x79cd92ce0Af4f0b383163D4D8B1B74Ad3444cdEC, poolId);
        // console.log(incrementMaxMirror0, incrementMaxMirror1);

        // (uint256 marginMax, uint256 borrowAmount) = IMarginLiquidity(0x13a1d5822A945A4022b1Bd160daa7E497F26ba3A)
        //     .getMarginMax(0x79cd92ce0Af4f0b383163D4D8B1B74Ad3444cdEC, poolId, true, 0);
        // console.log(marginMax, borrowAmount);
        Currency usdt = Currency.wrap(0x089f50aC197C68E1bab2782435ce50f1aFc8C656);

        uint256 amount = IPoolStatusManager(0xFb3006590FCCCa9f39958cf042EaF9cff06aAead).balanceOf(
            0x79347d7207C5c99445E6E386f1CCcbB31bfe3b1B, usdt.toTokenId(poolId)
        );
        console.log(amount);
        amount = IPoolStatusManager(0xFb3006590FCCCa9f39958cf042EaF9cff06aAead).balanceOf(
            0x331E162Fb8bfd397B7B38e3a6cd4601A3ecD46Fe, usdt.toTokenId(poolId)
        );
        console.log(amount);
        amount = IPoolStatusManager(0xFb3006590FCCCa9f39958cf042EaF9cff06aAead).balanceOriginal(
            0x331E162Fb8bfd397B7B38e3a6cd4601A3ecD46Fe, usdt.toTokenId(poolId)
        );
        console.log("balanceOriginal:", amount);
        amount = IPoolStatusManager(0xFb3006590FCCCa9f39958cf042EaF9cff06aAead).balanceOriginal(
            0x79347d7207C5c99445E6E386f1CCcbB31bfe3b1B, usdt.toTokenId(poolId)
        );
        console.log("balanceOriginal:", amount);
        amount = IPoolStatusManager(0xFb3006590FCCCa9f39958cf042EaF9cff06aAead).balanceOf(
            0xFb3006590FCCCa9f39958cf042EaF9cff06aAead, usdt.toTokenId(poolId)
        );
        console.log(amount);
        amount = IPoolStatusManager(0xFb3006590FCCCa9f39958cf042EaF9cff06aAead).balanceOriginal(
            0xFb3006590FCCCa9f39958cf042EaF9cff06aAead, usdt.toTokenId(poolId)
        );
        console.log("balanceOriginal:", amount);
        amount = IPoolStatusManager(0x7cAf3F63D481555361Ad3b17703Ac95f7a320D0c).balanceOf(
            0xFb3006590FCCCa9f39958cf042EaF9cff06aAead, usdt.toId()
        );
        console.log(amount);
        // MarginChecker marginChecker = new MarginChecker(user);
        // IMarginPositionManager(0x576f1E914b2b0266C66551a8e6934393D160A4fE).setMarginChecker(address(marginChecker));
    }
}
