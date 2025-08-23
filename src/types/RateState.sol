// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

type RateState is bytes32;

using RateStateLibrary for RateState global;

/// @notice Library for getting and setting values in the RateState type
library RateStateLibrary {
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;

    uint8 internal constant USE_MIDDLE_LEVEL_OFFSET = 24;
    uint8 internal constant USE_HIGH_LEVEL_OFFSET = 48;
    uint8 internal constant M_LOW_OFFSET = 72;
    uint8 internal constant M_MIDDLE_OFFSET = 96;
    uint8 internal constant M_HIGH_OFFSET = 120;

    // #### GETTERS ####
    function rateBase(RateState _packed) internal pure returns (uint24 _rateBase) {
        assembly ("memory-safe") {
            _rateBase := and(MASK_24_BITS, _packed)
        }
    }

    function useMiddleLevel(RateState _packed) internal pure returns (uint24 _useMiddleLevel) {
        assembly ("memory-safe") {
            _useMiddleLevel := and(MASK_24_BITS, shr(USE_MIDDLE_LEVEL_OFFSET, _packed))
        }
    }

    function useHighLevel(RateState _packed) internal pure returns (uint24 _useHighLevel) {
        assembly ("memory-safe") {
            _useHighLevel := and(MASK_24_BITS, shr(USE_HIGH_LEVEL_OFFSET, _packed))
        }
    }

    function mLow(RateState _packed) internal pure returns (uint24 _mLow) {
        assembly ("memory-safe") {
            _mLow := and(MASK_24_BITS, shr(M_LOW_OFFSET, _packed))
        }
    }

    function mMiddle(RateState _packed) internal pure returns (uint24 _mMiddle) {
        assembly ("memory-safe") {
            _mMiddle := and(MASK_24_BITS, shr(M_MIDDLE_OFFSET, _packed))
        }
    }

    function mHigh(RateState _packed) internal pure returns (uint24 _mHigh) {
        assembly ("memory-safe") {
            _mHigh := and(MASK_24_BITS, shr(M_HIGH_OFFSET, _packed))
        }
    }

    // #### SETTERS ####
    function setRateBase(RateState _packed, uint24 _rateBase) internal pure returns (RateState _result) {
        assembly ("memory-safe") {
            _result := or(and(not(MASK_24_BITS), _packed), and(MASK_24_BITS, _rateBase))
        }
    }

    function setUseMiddleLevel(RateState _packed, uint24 _useMiddleLevel) internal pure returns (RateState _result) {
        assembly ("memory-safe") {
            _result :=
                or(
                    and(not(shl(USE_MIDDLE_LEVEL_OFFSET, MASK_24_BITS)), _packed),
                    shl(USE_MIDDLE_LEVEL_OFFSET, and(MASK_24_BITS, _useMiddleLevel))
                )
        }
    }

    function setUseHighLevel(RateState _packed, uint24 _useHighLevel) internal pure returns (RateState _result) {
        assembly ("memory-safe") {
            _result :=
                or(
                    and(not(shl(USE_HIGH_LEVEL_OFFSET, MASK_24_BITS)), _packed),
                    shl(USE_HIGH_LEVEL_OFFSET, and(MASK_24_BITS, _useHighLevel))
                )
        }
    }

    function setMLow(RateState _packed, uint24 _mLow) internal pure returns (RateState _result) {
        assembly ("memory-safe") {
            _result :=
                or(
                    and(not(shl(M_LOW_OFFSET, MASK_24_BITS)), _packed),
                    shl(M_LOW_OFFSET, and(MASK_24_BITS, _mLow))
                )
        }
    }

    function setMMiddle(RateState _packed, uint24 _mMiddle) internal pure returns (RateState _result) {
        assembly ("memory-safe") {
            _result :=
                or(
                    and(not(shl(M_MIDDLE_OFFSET, MASK_24_BITS)), _packed),
                    shl(M_MIDDLE_OFFSET, and(MASK_24_BITS, _mMiddle))
                )
        }
    }

    function setMHigh(RateState _packed, uint24 _mHigh) internal pure returns (RateState _result) {
        assembly ("memory-safe") {
            _result :=
                or(
                    and(not(shl(M_HIGH_OFFSET, MASK_24_BITS)), _packed),
                    shl(M_HIGH_OFFSET, and(MASK_24_BITS, _mHigh))
                )
        }
    }
}