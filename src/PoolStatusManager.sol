// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {BaseFees} from "./base/BaseFees.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {BalanceStatus} from "./types/BalanceStatus.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";
import {TransientSlot} from "./external/openzeppelin-contracts/TransientSlot.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IMarginOracleWriter} from "./interfaces/IMarginOracleWriter.sol";
import {IPoolStatusManager} from "./interfaces/IPoolStatusManager.sol";

contract PoolStatusManager is IPoolStatusManager, BaseFees, Owned {
    using UQ112x112 for *;
    using TransientSlot for *;
    using CurrencyPoolLibrary for *;
    using PoolStatusLibrary for *;

    error UpdateBalanceGuardErrorCall();
    error NotPairPoolManager();
    error PairAlreadyExists();
    error PairNotExists();

    event Sync(
        PoolId indexed poolId,
        uint256 realReserve0,
        uint256 realReserve1,
        uint256 mirrorReserve0,
        uint256 mirrorReserve1,
        uint256 lendingRealReserve0,
        uint256 lendingRealReserve1,
        uint256 lendingMirrorReserve0,
        uint256 lendingMirrorReserve1
    );

    IPoolManager public immutable poolManager;
    IMirrorTokenManager public immutable mirrorTokenManager;
    ILendingPoolManager public immutable lendingPoolManager;
    IMarginLiquidity public immutable marginLiquidity;
    address public immutable pairPoolManager;
    IMarginFees public marginFees;
    address public marginOracle;

    mapping(PoolId => PoolStatus) private statusStore;
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
        ILendingPoolManager _lendingPoolManager,
        IMarginLiquidity _marginLiquidity,
        IPairPoolManager _pairPoolManager,
        IMarginFees _marginFees
    ) Owned(initialOwner) {
        poolManager = _poolManager;
        mirrorTokenManager = _mirrorTokenManager;
        lendingPoolManager = _lendingPoolManager;
        marginLiquidity = _marginLiquidity;
        pairPoolManager = address(_pairPoolManager);
        marginFees = _marginFees;
    }

    modifier onlyPairPoolManager() {
        if (msg.sender != pairPoolManager || msg.sender == address(this)) revert NotPairPoolManager();
        _;
    }

    function hooks() external view returns (IHooks hook) {
        return IPairPoolManager(pairPoolManager).hooks();
    }

    function getStatus(PoolId poolId) public view returns (PoolStatus memory _status) {
        _status = statusStore[poolId];
        if (_status.key.currency1 == CurrencyLibrary.ADDRESS_ZERO) revert PairNotExists();
        (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = marginFees.getBorrowRateCumulativeLast(_status);
        _status.mirrorReserve0 =
            uint112(Math.mulDiv(_status.mirrorReserve0, rate0CumulativeLast, _status.rate0CumulativeLast));
        _status.mirrorReserve1 =
            uint112(Math.mulDiv(_status.mirrorReserve1, rate1CumulativeLast, _status.rate1CumulativeLast));
        _status.blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        _status.rate0CumulativeLast = rate0CumulativeLast;
        _status.rate1CumulativeLast = rate1CumulativeLast;
    }

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1) {
        PoolStatus memory status = getStatus(poolId);
        (_reserve0, _reserve1) = status.getReserves();
    }

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut) external view returns (uint256 amountIn) {
        PoolStatus memory status = getStatus(poolId);
        (amountIn,,) = marginFees.getAmountIn(address(this), status, zeroForOne, amountOut);
    }

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
        PoolStatus memory status = getStatus(poolId);
        (amountOut,,) = marginFees.getAmountOut(address(this), status, zeroForOne, amountIn);
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

    function _updateInterest0(
        PoolStatus storage status,
        uint256 flowReserve0,
        uint256 rate0CumulativeLast,
        bool inUpdate
    ) internal returns (uint256 interest0) {
        if (status.mirrorReserve0 > 0 && rate0CumulativeLast > status.rate0CumulativeLast) {
            uint256 mirrorReserve0 = status.mirrorReserve0 + status.lendingMirrorReserve0;
            uint256 allInterest0 =
                Math.mulDiv(mirrorReserve0, rate0CumulativeLast, status.rate0CumulativeLast) - mirrorReserve0;
            interest0 = Math.mulDiv(allInterest0, flowReserve0, flowReserve0 + status.lendingReserve0());
            if (!inUpdate) {
                status.mirrorReserve0 += uint112(interest0);
            }
            uint256 cPoolId = status.key.currency0.toTokenId(status.key);
            if (allInterest0 > interest0) {
                uint256 lendingInterest0 = allInterest0 - interest0;
                uint256 lendingRealInterest0 =
                    Math.mulDiv(lendingInterest0, status.lendingRealReserve0, status.lendingReserve0());
                uint256 lendingMirrorInterest0 = lendingInterest0 - lendingRealInterest0;
                if (!inUpdate) {
                    status.lendingRealReserve0 += lendingRealInterest0.toUint112();
                    status.lendingMirrorReserve0 += lendingMirrorInterest0.toUint112();
                }
                lendingPoolManager.updateInterests(cPoolId, lendingInterest0);
                mirrorTokenManager.mintInStatus(address(lendingPoolManager), cPoolId, lendingMirrorInterest0);
            }
            mirrorTokenManager.mintInStatus(pairPoolManager, cPoolId, interest0);
        }
    }

    function _updateInterest1(
        PoolStatus storage status,
        uint256 flowReserve1,
        uint256 rate1CumulativeLast,
        bool inUpdate
    ) internal returns (uint256 interest1) {
        if (status.mirrorReserve1 > 0 && rate1CumulativeLast > status.rate1CumulativeLast) {
            uint256 mirrorReserve1 = status.mirrorReserve1 + status.lendingMirrorReserve1;
            uint256 allInterest1 =
                Math.mulDiv(mirrorReserve1, rate1CumulativeLast, status.rate1CumulativeLast) - mirrorReserve1;
            interest1 = Math.mulDiv(allInterest1, flowReserve1, flowReserve1 + status.lendingReserve1());
            if (!inUpdate) {
                status.mirrorReserve1 += interest1.toUint112();
            }
            uint256 cPoolId = status.key.currency1.toTokenId(status.key);
            if (allInterest1 > interest1) {
                uint256 lendingInterest1 = allInterest1 - interest1;
                uint256 lendingRealInterest1 =
                    Math.mulDiv(lendingInterest1, status.lendingRealReserve1, status.lendingReserve1());
                uint256 lendingMirrorInterest1 = lendingInterest1 - lendingRealInterest1;
                if (!inUpdate) {
                    status.lendingRealReserve1 += lendingRealInterest1.toUint112();
                    status.lendingMirrorReserve1 += lendingMirrorInterest1.toUint112();
                }
                lendingPoolManager.updateInterests(cPoolId, lendingInterest1);
                mirrorTokenManager.mintInStatus(address(lendingPoolManager), cPoolId, lendingMirrorInterest1);
            }
            mirrorTokenManager.mintInStatus(pairPoolManager, cPoolId, interest1);
        }
    }

    function _updateInterests(PoolStatus storage status, bool inUpdate) internal {
        PoolKey memory key = status.key;
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (status.blockTimestampLast != blockTS && (status.mirrorReserve0 + status.mirrorReserve1 > 0)) {
            PoolId poolId = key.toId();
            (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = marginFees.getBorrowRateCumulativeLast(status);
            (uint256 flowReserve0, uint256 flowReserve1) =
                marginLiquidity.getInterestReserves(pairPoolManager, poolId, status);
            uint256 interest0 = _updateInterest0(status, flowReserve0, rate0CumulativeLast, inUpdate);
            uint256 interest1 = _updateInterest1(status, flowReserve1, rate1CumulativeLast, inUpdate);
            status.blockTimestampLast = blockTS;
            status.rate0CumulativeLast = rate0CumulativeLast;
            status.rate1CumulativeLast = rate1CumulativeLast;
            marginLiquidity.addInterests(poolId, status.reserve0(), status.reserve1(), interest0, interest1);
            if (interest0 > 0) {
                emit Fees(poolId, key.currency0, address(this), uint8(FeeType.INTERESTS), interest0);
            }
            if (interest1 > 0) {
                emit Fees(poolId, key.currency1, address(this), uint8(FeeType.INTERESTS), interest1);
            }
        }
    }

    // ******************** OWNER CALL ********************

    function setFeeStatus(PoolId poolId, uint24 _marginFee) external onlyOwner {
        statusStore[poolId].marginFee = _marginFee;
    }

    function setMarginFees(address _marginFees) external onlyOwner {
        marginFees = IMarginFees(_marginFees);
    }

    function setMarginOracle(address _oracle) external onlyOwner {
        marginOracle = _oracle;
    }

    // ******************** PAIR_POOL_MANAGER CALL ********************

    function initialize(PoolKey calldata key) external onlyPairPoolManager {
        PoolId id = key.toId();
        if (statusStore[id].key.currency1 > CurrencyLibrary.ADDRESS_ZERO) revert PairAlreadyExists();
        PoolStatus memory status;
        status.key = key;
        status.rate0CumulativeLast = PerLibrary.ONE_TRILLION;
        status.rate1CumulativeLast = PerLibrary.ONE_TRILLION;
        status.blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        statusStore[id] = status;
    }

    function getBalances(PoolKey memory key)
        public
        view
        onlyPairPoolManager
        returns (BalanceStatus memory balanceStatus)
    {
        uint256 protocolFees0 = protocolFeesAccrued[key.currency0];
        uint256 protocolFees1 = protocolFeesAccrued[key.currency1];
        balanceStatus.balance0 = poolManager.balanceOf(pairPoolManager, key.currency0.toId());
        if (balanceStatus.balance0 > protocolFees0) {
            balanceStatus.balance0 -= protocolFees0;
        } else {
            balanceStatus.balance0 = 0;
        }
        balanceStatus.balance1 = poolManager.balanceOf(pairPoolManager, key.currency1.toId());
        if (balanceStatus.balance1 > protocolFees1) {
            balanceStatus.balance1 -= protocolFees1;
        } else {
            balanceStatus.balance1 = 0;
        }
        uint256 id0 = key.currency0.toTokenId(key);
        uint256 id1 = key.currency1.toTokenId(key);
        balanceStatus.mirrorBalance0 = mirrorTokenManager.balanceOf(pairPoolManager, id0);
        balanceStatus.mirrorBalance1 = mirrorTokenManager.balanceOf(pairPoolManager, id1);

        balanceStatus.lendingBalance0 = lendingPoolManager.balanceOf(address(lendingPoolManager), id0);
        balanceStatus.lendingBalance1 = lendingPoolManager.balanceOf(address(lendingPoolManager), id1);
        balanceStatus.lendingMirrorBalance0 = mirrorTokenManager.balanceOf(address(lendingPoolManager), id0);
        balanceStatus.lendingMirrorBalance1 = mirrorTokenManager.balanceOf(address(lendingPoolManager), id1);
    }

    function setBalances(PoolKey memory key)
        external
        onlyPairPoolManager
        returns (BalanceStatus memory balanceStatus)
    {
        _callSet();
        balanceStatus = getBalances(key);
        BALANCE_0_SLOT.asUint256().tstore(balanceStatus.balance0);
        BALANCE_1_SLOT.asUint256().tstore(balanceStatus.balance1);
        MIRROR_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.mirrorBalance0);
        MIRROR_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.mirrorBalance1);
        LENDING_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.lendingBalance0);
        LENDING_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.lendingBalance1);
        LENDING_MIRROR_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.lendingMirrorBalance0);
        LENDING_MIRROR_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.lendingMirrorBalance1);
    }

    function updateInterests(PoolKey memory key) external onlyPairPoolManager {
        PoolId pooId = key.toId();
        PoolStatus storage status = statusStore[pooId];
        _updateInterests(status, false);
    }

    function update(PoolKey memory key, bool fromMargin)
        public
        onlyPairPoolManager
        returns (BalanceStatus memory afterStatus)
    {
        PoolId pooId = key.toId();
        PoolStatus storage status = statusStore[pooId];
        // save margin price before changed
        if (fromMargin) {
            uint32 blockTS = uint32(block.timestamp % 2 ** 32);
            if (status.marginTimestampLast != blockTS) {
                status.marginTimestampLast = blockTS;
            }
        }

        BalanceStatus memory beforeStatus = _getBalances();
        _updateInterests(status, true);
        afterStatus = getBalances(key);
        status.realReserve0 = status.realReserve0.add(afterStatus.balance0).sub(beforeStatus.balance0);
        status.realReserve1 = status.realReserve1.add(afterStatus.balance1).sub(beforeStatus.balance1);
        status.mirrorReserve0 = status.mirrorReserve0.add(afterStatus.mirrorBalance0).sub(beforeStatus.mirrorBalance0);
        status.mirrorReserve1 = status.mirrorReserve1.add(afterStatus.mirrorBalance1).sub(beforeStatus.mirrorBalance1);
        status.lendingRealReserve0 =
            status.lendingRealReserve0.add(afterStatus.lendingBalance0).sub(beforeStatus.lendingBalance0);
        status.lendingRealReserve1 =
            status.lendingRealReserve1.add(afterStatus.lendingBalance1).sub(beforeStatus.lendingBalance1);
        status.lendingMirrorReserve0 =
            status.lendingMirrorReserve0.add(afterStatus.lendingMirrorBalance0).sub(beforeStatus.lendingMirrorBalance0);
        status.lendingMirrorReserve1 =
            status.lendingMirrorReserve1.add(afterStatus.lendingMirrorBalance1).sub(beforeStatus.lendingMirrorBalance1);

        uint112 _reserve0 = status.reserve0();
        uint112 _reserve1 = status.reserve1();
        if (marginOracle != address(0)) {
            IMarginOracleWriter(marginOracle).write(status.key, _reserve0, _reserve1);
        }

        emit Sync(
            pooId,
            status.realReserve0,
            status.realReserve1,
            status.mirrorReserve0,
            status.mirrorReserve1,
            status.lendingRealReserve0,
            status.lendingRealReserve1,
            status.lendingMirrorReserve0,
            status.lendingMirrorReserve1
        );
        _callUpdate();
    }

    function update(PoolKey memory key) external onlyPairPoolManager returns (BalanceStatus memory afterStatus) {
        afterStatus = update(key, false);
    }

    function updateProtocolFees(Currency currency, uint256 amount)
        external
        onlyPairPoolManager
        returns (uint256 restAmount)
    {
        unchecked {
            uint256 protocolFees = marginFees.getProtocolFeeAmount(amount);
            protocolFeesAccrued[currency] += protocolFees;
            restAmount = amount - protocolFees;
        }
    }

    function collectProtocolFees(Currency currency, uint256 amount)
        external
        onlyPairPoolManager
        returns (uint256 amountCollected)
    {
        amountCollected = (amount == 0) ? protocolFeesAccrued[currency] : amount;
        unchecked {
            protocolFeesAccrued[currency] -= amountCollected;
        }
    }
}
