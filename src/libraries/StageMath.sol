// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UQ112x112} from "./UQ112x112.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {TimeLibrary} from "./TimeLibrary.sol";

library StageMath {
    function encode(uint40 timestamp, uint256 liquidity) internal pure returns (uint256 stage) {
        stage = (uint256(timestamp) << 216) + liquidity;
    }

    function decode(uint256 stage) internal pure returns (uint40 timestamp, uint256 liquidity) {
        timestamp = uint40(stage >> 216);
        liquidity = stage & ((1 << 216) - 1);
    }
}
