// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeCast} from "../libraries/SafeCast.sol";
import {
    BalanceDelta,
    toBalanceDelta as toBalanceDeltaInternal,
    add as addInternal,
    sub as subInternal,
    eq as eqInternal,
    neq as neqInternal,
    BalanceDeltaLibrary
} from "./BalanceDelta.sol";

/// @dev Two `int128` values packed into a single `int256`. Serves as a semantic alias for BalanceDelta for insurance funds.
type InsuranceFunds is int256;

using {add as +, sub as -, eq as ==, neq as !=} for InsuranceFunds global;
using InsuranceFundsLibrary for InsuranceFunds global;
using SafeCast for int256;

function toInsuranceFunds(int128 _amount0, int128 _amount1) pure returns (InsuranceFunds) {
    return InsuranceFunds.wrap(BalanceDelta.unwrap(toBalanceDeltaInternal(_amount0, _amount1)));
}

function add(InsuranceFunds a, InsuranceFunds b) pure returns (InsuranceFunds) {
    BalanceDelta bdA = BalanceDelta.wrap(InsuranceFunds.unwrap(a));
    BalanceDelta bdB = BalanceDelta.wrap(InsuranceFunds.unwrap(b));
    return InsuranceFunds.wrap(BalanceDelta.unwrap(addInternal(bdA, bdB)));
}

function sub(InsuranceFunds a, InsuranceFunds b) pure returns (InsuranceFunds) {
    BalanceDelta bdA = BalanceDelta.wrap(InsuranceFunds.unwrap(a));
    BalanceDelta bdB = BalanceDelta.wrap(InsuranceFunds.unwrap(b));
    return InsuranceFunds.wrap(BalanceDelta.unwrap(subInternal(bdA, bdB)));
}

function eq(InsuranceFunds a, InsuranceFunds b) pure returns (bool) {
    return eqInternal(BalanceDelta.wrap(InsuranceFunds.unwrap(a)), BalanceDelta.wrap(InsuranceFunds.unwrap(b)));
}

function neq(InsuranceFunds a, InsuranceFunds b) pure returns (bool) {
    return neqInternal(BalanceDelta.wrap(InsuranceFunds.unwrap(a)), BalanceDelta.wrap(InsuranceFunds.unwrap(b)));
}

library InsuranceFundsLibrary {
    InsuranceFunds public constant ZERO_DELTA = InsuranceFunds.wrap(0);

    function amount0(InsuranceFunds f) internal pure returns (int128) {
        return BalanceDeltaLibrary.amount0(BalanceDelta.wrap(InsuranceFunds.unwrap(f)));
    }

    function amount1(InsuranceFunds f) internal pure returns (int128) {
        return BalanceDeltaLibrary.amount1(BalanceDelta.wrap(InsuranceFunds.unwrap(f)));
    }

    function unpack(InsuranceFunds f) internal pure returns (int128, int128) {
        return (f.amount0(), f.amount1());
    }
}
