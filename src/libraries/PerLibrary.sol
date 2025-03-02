// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library PerLibrary {
    uint256 public constant ONE_MILLION = 10 ** 6;

    function mulMillion(uint256 x) internal pure returns (uint256 y) {
        y = x * ONE_MILLION;
    }

    function divMillion(uint256 x) internal pure returns (uint256 y) {
        y = x / ONE_MILLION;
    }

    function mulMillionDiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = Math.mulDiv(x, ONE_MILLION, y);
    }

    function mulDivMillion(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = Math.mulDiv(x, y, ONE_MILLION);
    }

    function upperMillion(uint256 x, uint256 y, uint256 per) internal pure returns (uint256 z) {
        z = Math.mulDiv(x, ONE_MILLION + per, y);
    }

    function lowerMillion(uint256 x, uint256 y, uint256 per) internal pure returns (uint256 z) {
        z = Math.mulDiv(x, ONE_MILLION - per, y);
    }
}
