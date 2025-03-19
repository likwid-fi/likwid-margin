// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {BaseFees} from "./base/BaseFees.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {BalanceStatus} from "./types/BalanceStatus.sol";
import {InterestBalance} from "./types/InterestBalance.sol";
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
    using SafeCast for uint256;
    using UQ112x112 for *;
    using TransientSlot for *;
    using CurrencyPoolLibrary for *;
    using PoolStatusLibrary for *;

    error UpdateBalanceGuardErrorCall();
    error NotPoolManager();
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

    modifier onlyPoolManager() {
        if (msg.sender != pairPoolManager) revert NotPoolManager();
        _;
    }

    modifier onlyLendingManager() {
        if (msg.sender != address(lendingPoolManager)) revert NotPoolManager();
        _;
    }

    function hooks() external view returns (IHooks hook) {
        return IPairPoolManager(pairPoolManager).hooks();
    }

    function getStatus(PoolId poolId) public view returns (PoolStatus memory _status) {
        _status = statusStore[poolId];
        if (_status.key.currency1 == CurrencyLibrary.ADDRESS_ZERO) revert PairNotExists();
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (_status.blockTimestampLast != blockTS && (_status.totalMirrorReserves() > 0)) {
            (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = marginFees.getBorrowRateCumulativeLast(_status);
            (uint256 interestReserve0, uint256 interestReserve1) =
                marginLiquidity.getInterestReserves(pairPoolManager, poolId, _status);
            InterestBalance memory interestStatus0 = _updateInterest0(_status, interestReserve0, rate0CumulativeLast);
            InterestBalance memory interestStatus1 = _updateInterest1(_status, interestReserve1, rate1CumulativeLast);
            if (interestStatus0.allInterest > 0) {
                if (interestStatus0.pairInterest > 0) {
                    _status.mirrorReserve0 += interestStatus0.pairInterest.toUint112();
                }
                if (interestStatus0.lendingInterest > 0) {
                    _status.lendingMirrorReserve0 += interestStatus0.lendingInterest.toUint112();
                }
            }

            if (interestStatus1.allInterest > 0) {
                if (interestStatus1.pairInterest > 0) {
                    _status.mirrorReserve1 += interestStatus1.pairInterest.toUint112();
                }
                if (interestStatus1.lendingInterest > 0) {
                    _status.lendingMirrorReserve1 += interestStatus1.lendingInterest.toUint112();
                }
            }

            _status.blockTimestampLast = blockTS;
            _status.rate0CumulativeLast = rate0CumulativeLast;
            _status.rate1CumulativeLast = rate1CumulativeLast;
        }
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

        return BalanceStatus(balance0, balance1, 0, 0, 0, 0, 0, 0);
    }

    function _getBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
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
    }

    function _getAllBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
        balanceStatus = _getBalances(key);
        uint256 id0 = key.currency0.toTokenId(key);
        uint256 id1 = key.currency1.toTokenId(key);
        balanceStatus.mirrorBalance0 = mirrorTokenManager.balanceOf(pairPoolManager, id0);
        balanceStatus.mirrorBalance1 = mirrorTokenManager.balanceOf(pairPoolManager, id1);

        balanceStatus.lendingTotalBalance0 = lendingPoolManager.balanceOf(address(lendingPoolManager), id0);
        balanceStatus.lendingTotalBalance1 = lendingPoolManager.balanceOf(address(lendingPoolManager), id1);
        balanceStatus.lendingMirrorBalance0 = mirrorTokenManager.balanceOf(address(lendingPoolManager), id0);
        balanceStatus.lendingMirrorBalance1 = mirrorTokenManager.balanceOf(address(lendingPoolManager), id1);
    }

    function _updateInterest0(PoolStatus memory status, uint256 interestReserve0, uint256 rate0CumulativeLast)
        internal
        pure
        returns (InterestBalance memory interestStatus)
    {
        uint256 mirrorReserve0 = status.totalMirrorReserve0();
        if (mirrorReserve0 > 0 && rate0CumulativeLast > status.rate0CumulativeLast) {
            uint256 allInterest0 =
                Math.mulDiv(mirrorReserve0, rate0CumulativeLast, status.rate0CumulativeLast) - mirrorReserve0;
            uint256 interest0 = Math.mulDiv(allInterest0, interestReserve0, interestReserve0 + status.lendingReserve0());
            interestStatus.allInterest = allInterest0;
            interestStatus.pairInterest = interest0;
            if (allInterest0 > interest0) {
                interestStatus.lendingInterest = allInterest0 - interest0;
            }
        }
    }

    function _updateInterest1(PoolStatus memory status, uint256 interestReserve1, uint256 rate1CumulativeLast)
        internal
        pure
        returns (InterestBalance memory interestStatus)
    {
        uint256 mirrorReserve1 = status.totalMirrorReserve1();
        if (mirrorReserve1 > 0 && rate1CumulativeLast > status.rate1CumulativeLast) {
            uint256 allInterest1 =
                Math.mulDiv(mirrorReserve1, rate1CumulativeLast, status.rate1CumulativeLast) - mirrorReserve1;

            uint256 interest1 = Math.mulDiv(allInterest1, interestReserve1, interestReserve1 + status.lendingReserve1());
            interestStatus.allInterest = allInterest1;
            interestStatus.pairInterest = interest1;
            if (allInterest1 > interest1) {
                interestStatus.lendingInterest = allInterest1 - interest1;
            }
        }
    }

    function _updateInterests(PoolStatus storage status) internal {
        PoolKey memory key = status.key;
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (status.blockTimestampLast != blockTS && (status.totalMirrorReserves() > 0)) {
            PoolId poolId = key.toId();
            uint256 interest0;
            uint256 interest1;
            {
                uint256 cPoolId0 = status.key.currency0.toTokenId(poolId);
                uint256 cPoolId1 = status.key.currency1.toTokenId(poolId);
                (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) =
                    marginFees.getBorrowRateCumulativeLast(status);
                (uint256 interestReserve0, uint256 interestReserve1) =
                    marginLiquidity.getInterestReserves(pairPoolManager, poolId, status);
                InterestBalance memory interestStatus0 = _updateInterest0(status, interestReserve0, rate0CumulativeLast);
                if (interestStatus0.allInterest > 0) {
                    if (interestStatus0.pairInterest > 0) {
                        interest0 = _updateProtocolFees(status.key.currency0, interestStatus0.pairInterest);
                        status.mirrorReserve0 += interestStatus0.pairInterest.toUint112();
                        mirrorTokenManager.mintInStatus(pairPoolManager, cPoolId0, interestStatus0.pairInterest);
                        emit Fees(
                            poolId, key.currency0, address(this), uint8(FeeType.INTERESTS), interestStatus0.pairInterest
                        );
                    }
                    if (interestStatus0.lendingInterest > 0) {
                        status.lendingMirrorReserve0 += interestStatus0.lendingInterest.toUint112();
                        lendingPoolManager.updateInterests(cPoolId0, interestStatus0.lendingInterest.toInt256());
                        mirrorTokenManager.mintInStatus(
                            address(lendingPoolManager), cPoolId0, interestStatus0.lendingInterest
                        );
                    }
                }

                InterestBalance memory interestStatus1 = _updateInterest1(status, interestReserve1, rate1CumulativeLast);
                if (interestStatus1.allInterest > 0) {
                    if (interestStatus1.pairInterest > 0) {
                        interest1 = _updateProtocolFees(status.key.currency1, interestStatus1.pairInterest);
                        status.mirrorReserve1 += interestStatus1.pairInterest.toUint112();
                        mirrorTokenManager.mintInStatus(pairPoolManager, cPoolId1, interestStatus1.pairInterest);
                        emit Fees(
                            poolId, key.currency1, address(this), uint8(FeeType.INTERESTS), interestStatus1.pairInterest
                        );
                    }
                    if (interestStatus1.lendingInterest > 0) {
                        status.lendingMirrorReserve1 += interestStatus1.lendingInterest.toUint112();
                        lendingPoolManager.updateInterests(cPoolId1, interestStatus1.lendingInterest.toInt256());
                        mirrorTokenManager.mintInStatus(
                            address(lendingPoolManager), cPoolId1, interestStatus1.lendingInterest
                        );
                    }
                }

                status.blockTimestampLast = blockTS;
                status.rate0CumulativeLast = rate0CumulativeLast;
                status.rate1CumulativeLast = rate1CumulativeLast;
            }
            if (interest0 + interest1 > 0) {
                marginLiquidity.addInterests(poolId, status.reserve0(), status.reserve1(), interest0, interest1);
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

    function initialize(PoolKey calldata key) external onlyPoolManager {
        PoolId id = key.toId();
        if (statusStore[id].key.currency1 > CurrencyLibrary.ADDRESS_ZERO) revert PairAlreadyExists();
        PoolStatus memory status;
        status.key = key;
        status.rate0CumulativeLast = PerLibrary.ONE_TRILLION;
        status.rate1CumulativeLast = PerLibrary.ONE_TRILLION;
        status.blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        statusStore[id] = status;
    }

    function setBalances(PoolId poolId) external onlyPoolManager returns (PoolStatus memory) {
        _callSet();
        PoolStatus storage status = statusStore[poolId];
        _updateInterests(status);
        BalanceStatus memory balanceStatus = _getBalances(status.key);
        BALANCE_0_SLOT.asUint256().tstore(balanceStatus.balance0);
        BALANCE_1_SLOT.asUint256().tstore(balanceStatus.balance1);
        return status;
    }

    function updateInterests(PoolId poolId) external onlyPoolManager returns (PoolStatus memory) {
        PoolStatus storage status = statusStore[poolId];
        _updateInterests(status);
        return status;
    }

    function update(PoolId poolId, bool fromMargin) public onlyPoolManager returns (BalanceStatus memory afterStatus) {
        PoolStatus storage status = statusStore[poolId];
        // save margin price before changed
        if (fromMargin) {
            uint32 blockTS = uint32(block.timestamp % 2 ** 32);
            if (status.marginTimestampLast != blockTS) {
                status.marginTimestampLast = blockTS;
            }
        }

        BalanceStatus memory beforeStatus = _getBalances();
        afterStatus = _getAllBalances(status.key);
        status.realReserve0 = status.realReserve0.add(afterStatus.balance0).sub(beforeStatus.balance0);
        status.realReserve1 = status.realReserve1.add(afterStatus.balance1).sub(beforeStatus.balance1);
        status.mirrorReserve0 = afterStatus.mirrorBalance0.toUint112();
        status.mirrorReserve1 = afterStatus.mirrorBalance1.toUint112();
        status.lendingMirrorReserve0 = afterStatus.lendingMirrorBalance0.toUint112();
        status.lendingMirrorReserve1 = afterStatus.lendingMirrorBalance1.toUint112();
        if (afterStatus.lendingTotalBalance0 > afterStatus.lendingMirrorBalance0) {
            status.lendingRealReserve0 =
                (afterStatus.lendingTotalBalance0 - afterStatus.lendingMirrorBalance0).toUint112();
        } else {
            status.lendingRealReserve0 = 0;
        }
        if (afterStatus.lendingTotalBalance1 > afterStatus.lendingMirrorBalance1) {
            status.lendingRealReserve1 =
                (afterStatus.lendingTotalBalance1 - afterStatus.lendingMirrorBalance1).toUint112();
        } else {
            status.lendingRealReserve1 = 0;
        }

        uint112 _reserve0 = status.reserve0();
        uint112 _reserve1 = status.reserve1();
        if (marginOracle != address(0)) {
            IMarginOracleWriter(marginOracle).write(status.key, _reserve0, _reserve1);
        }

        emit Sync(
            poolId,
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

    function update(PoolId poolId) external onlyPoolManager returns (BalanceStatus memory afterStatus) {
        afterStatus = update(poolId, false);
    }

    function updateLendingPoolStatus(PoolId poolId) external onlyLendingManager {
        PoolStatus storage status = statusStore[poolId];
        _updateInterests(status);
        BalanceStatus memory afterStatus = _getAllBalances(status.key);
        status.mirrorReserve0 = afterStatus.mirrorBalance0.toUint112();
        status.mirrorReserve1 = afterStatus.mirrorBalance1.toUint112();
        status.lendingMirrorReserve0 = afterStatus.lendingMirrorBalance0.toUint112();
        status.lendingMirrorReserve1 = afterStatus.lendingMirrorBalance1.toUint112();
        if (afterStatus.lendingTotalBalance0 > afterStatus.lendingMirrorBalance0) {
            status.lendingRealReserve0 =
                (afterStatus.lendingTotalBalance0 - afterStatus.lendingMirrorBalance0).toUint112();
        } else {
            status.lendingRealReserve0 = 0;
        }
        if (afterStatus.lendingTotalBalance1 > afterStatus.lendingMirrorBalance1) {
            status.lendingRealReserve1 =
                (afterStatus.lendingTotalBalance1 - afterStatus.lendingMirrorBalance1).toUint112();
        } else {
            status.lendingRealReserve1 = 0;
        }
        emit Sync(
            poolId,
            status.realReserve0,
            status.realReserve1,
            status.mirrorReserve0,
            status.mirrorReserve1,
            status.lendingRealReserve0,
            status.lendingRealReserve1,
            status.lendingMirrorReserve0,
            status.lendingMirrorReserve1
        );
    }

    function _updateProtocolFees(Currency currency, uint256 amount) internal returns (uint256 restAmount) {
        unchecked {
            uint256 protocolFees = marginFees.getProtocolFeeAmount(amount);
            protocolFeesAccrued[currency] += protocolFees;
            restAmount = amount - protocolFees;
        }
    }

    function updateProtocolFees(Currency currency, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 restAmount)
    {
        restAmount = _updateProtocolFees(currency, amount);
    }

    function collectProtocolFees(Currency currency, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 amountCollected)
    {
        amountCollected = (amount == 0) ? protocolFeesAccrued[currency] : amount;
        unchecked {
            protocolFeesAccrued[currency] -= amountCollected;
        }
    }
}
