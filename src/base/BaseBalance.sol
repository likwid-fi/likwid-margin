// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

import {BasePool} from "./BasePool.sol";
import {BalanceStatus} from "../types/BalanceStatus.sol";
import {CurrencyUtils} from "../libraries/CurrencyUtils.sol";
import {TransientSlot} from "../external/openzeppelin-contracts/TransientSlot.sol";
import {ILendingPoolManager} from "../interfaces/ILendingPoolManager.sol";
import {IMirrorTokenManager} from "../interfaces/IMirrorTokenManager.sol";

abstract contract BaseBalance is BasePool {
    using TransientSlot for *;
    using CurrencyUtils for *;

    error UpdateBalanceGuardErrorCall();

    IMirrorTokenManager public immutable mirrorTokenManager;
    ILendingPoolManager immutable lendingPoolManager;
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;

    bytes32 constant UPDATE_BALANCE_GUARD_SLOT = 0x885c9ad615c28a45189565668235695fb42940589d40d91c5c875c16cdc1bd4c;
    bytes32 constant BALANCE_0_SLOT = 0x608a02038d3023ed7e79ffc2a87ce7ad8c0bc0c5b839ddbe438db934c7b5e0e2;
    bytes32 constant BALANCE_1_SLOT = 0xba598ef587ec4c4cf493fe15321596d40159e5c3c0cbf449810c8c6894b2e5e1;
    bytes32 constant MIRROR_BALANCE_0_SLOT = 0x63450183817719ccac1ebea450ccc19412314611d078d8a8cb3ac9a1ef4de386;
    bytes32 constant MIRROR_BALANCE_1_SLOT = 0xbdb25f21ec501c2e41736c4e3dd44c1c3781af532b6899c36b3f72d4e003b0ab;
    bytes32 constant LENDING_BALANCE_0_SLOT = 0xa186fed6f032437b8a48cdc0974abb68692f2e91b72fc868edc12eb4858e3bb1;
    bytes32 constant LENDING_BALANCE_1_SLOT = 0x73c0bdc07d4c1d10eb4a663f9c8e3bcc3df61d0f218e56d20ecb859d66dcfdf4;
    bytes32 constant LENDING_MIRROR_BALANCE_0_SLOT = 0x4f1feacba32475151e92cfda35651960c8fc483e4629e3379ec7cc99f6d6f5f8;
    bytes32 constant LENDING_MIRROR_BALANCE_1_SLOT = 0xd8208f88c7357fd3d32bb5f64c2ff7bb8aacb281f65c6cf8506ca21370c89aae;

    constructor(
        address initialOwner,
        IPoolManager _poolManager,
        IMirrorTokenManager _mirrorTokenManager,
        ILendingPoolManager _lendingPoolManager
    ) BasePool(initialOwner, _poolManager) {
        mirrorTokenManager = _mirrorTokenManager;
        lendingPoolManager = _lendingPoolManager;
    }

    function _callSet() internal {
        if (_notCallUpdate()) {
            revert UpdateBalanceGuardErrorCall();
        }

        UPDATE_BALANCE_GUARD_SLOT.asBoolean().tstore(true);
    }

    function _callUpdate() internal {
        UPDATE_BALANCE_GUARD_SLOT.asBoolean().tstore(false);
    }

    function _notCallUpdate() internal view returns (bool) {
        return UPDATE_BALANCE_GUARD_SLOT.asBoolean().tload();
    }

    function _getBalances() internal view returns (BalanceStatus memory) {
        uint256 balance0 = BALANCE_0_SLOT.asUint256().tload();
        uint256 balance1 = BALANCE_1_SLOT.asUint256().tload();
        uint256 mirrorBalance0 = MIRROR_BALANCE_0_SLOT.asUint256().tload();
        uint256 mirrorBalance1 = MIRROR_BALANCE_1_SLOT.asUint256().tload();
        uint256 lendingBalance0 = LENDING_BALANCE_0_SLOT.asUint256().tload();
        uint256 lendingBalance1 = LENDING_BALANCE_1_SLOT.asUint256().tload();
        uint256 lendingMirrorBalance0 = LENDING_MIRROR_BALANCE_0_SLOT.asUint256().tload();
        uint256 lendingMirrorBalance1 = LENDING_MIRROR_BALANCE_1_SLOT.asUint256().tload();
        return BalanceStatus(
            balance0,
            balance1,
            mirrorBalance0,
            mirrorBalance1,
            lendingBalance0,
            lendingBalance1,
            lendingMirrorBalance0,
            lendingMirrorBalance1
        );
    }

    function _getBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
        uint256 protocolFees0 = protocolFeesAccrued[key.currency0];
        uint256 protocolFees1 = protocolFeesAccrued[key.currency1];
        balanceStatus.balance0 = poolManager.balanceOf(address(this), key.currency0.toId());
        if (balanceStatus.balance0 > protocolFees0) {
            balanceStatus.balance0 -= protocolFees0;
        } else {
            balanceStatus.balance0 = 0;
        }
        balanceStatus.balance1 = poolManager.balanceOf(address(this), key.currency1.toId());
        if (balanceStatus.balance1 > protocolFees1) {
            balanceStatus.balance1 -= protocolFees1;
        } else {
            balanceStatus.balance1 = 0;
        }
        balanceStatus.mirrorBalance0 = mirrorTokenManager.balanceOf(address(this), key.currency0.toKeyId(key));
        balanceStatus.mirrorBalance1 = mirrorTokenManager.balanceOf(address(this), key.currency1.toKeyId(key));

        balanceStatus.lendingBalance0 = poolManager.balanceOf(address(lendingPoolManager), key.currency0.toId());
        balanceStatus.lendingBalance1 = poolManager.balanceOf(address(lendingPoolManager), key.currency1.toId());
        balanceStatus.lendingMirrorBalance0 =
            mirrorTokenManager.balanceOf(address(lendingPoolManager), key.currency0.toKeyId(key));
        balanceStatus.lendingMirrorBalance1 =
            mirrorTokenManager.balanceOf(address(lendingPoolManager), key.currency1.toKeyId(key));
    }

    function _setBalances(PoolKey memory key) internal returns (BalanceStatus memory balanceStatus) {
        _callSet();
        balanceStatus = _getBalances(key);
        BALANCE_0_SLOT.asUint256().tstore(balanceStatus.balance0);
        BALANCE_1_SLOT.asUint256().tstore(balanceStatus.balance1);
        MIRROR_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.mirrorBalance0);
        MIRROR_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.mirrorBalance1);
        LENDING_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.lendingBalance0);
        LENDING_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.lendingBalance1);
        LENDING_MIRROR_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.lendingMirrorBalance0);
        LENDING_MIRROR_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.lendingMirrorBalance1);
    }
}
