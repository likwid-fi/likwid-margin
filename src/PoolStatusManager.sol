// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// Openzeppelin
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
// Likwid V2 core
import {IPoolManager} from "likwid-v2-core/interfaces/IPoolManager.sol";
import {IHooks} from "likwid-v2-core/interfaces/IHooks.sol";
import {PoolId} from "likwid-v2-core/types/PoolId.sol";
import {PoolKey} from "likwid-v2-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "likwid-v2-core/types/Currency.sol";
// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {BaseFees} from "./base/BaseFees.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {BalanceStatus} from "./types/BalanceStatus.sol";
import {InterestBalance} from "./types/InterestBalance.sol";
import {GlobalStatus} from "./types/GlobalStatus.sol";
import {LendingStatus} from "./types/LendingStatus.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {PoolStatusLibrary} from "./types/PoolStatusLibrary.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";
import {IMarginLiquidity} from "./interfaces/IMarginLiquidity.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {ILendingPoolManager} from "./interfaces/ILendingPoolManager.sol";
import {IMirrorTokenManager} from "./interfaces/IMirrorTokenManager.sol";
import {IMarginFees} from "./interfaces/IMarginFees.sol";
import {IPoolStatusManager} from "./interfaces/IPoolStatusManager.sol";

contract PoolStatusManager is IPoolStatusManager, BaseFees, Owned {
    using SafeCast for uint256;
    using UQ112x112 for *;
    using TransientSlot for *;
    using CurrencyPoolLibrary for *;
    using PoolStatusLibrary for *;
    using FeeLibrary for *;
    using PerLibrary for *;
    using TimeLibrary for uint32;

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

    event MarginFeesChanged(address indexed oldMarginFees, address indexed newMarginFees);

    IPoolManager public immutable poolManager;
    IMirrorTokenManager public immutable mirrorTokenManager;
    ILendingPoolManager public immutable lendingPoolManager;
    IMarginLiquidity public immutable marginLiquidity;
    address public immutable pairPoolManager;
    IMarginFees public marginFees;
    mapping(PoolId => bool) public interestClosed;

    mapping(PoolId => PoolStatus) private statusStore;
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;
    uint32 public maxPriceMovePerSecond = 3000; // 0.3%/second
    mapping(PoolId => uint256) public interestX112Store0;
    mapping(PoolId => uint256) public interestX112Store1;

    bytes32 constant UPDATE_BALANCE_GUARD_SLOT = 0x885c9ad615c28a45189565668235695fb42940589d40d91c5c875c16cdc1bd4c;
    bytes32 constant BALANCE_0_SLOT = 0x608a02038d3023ed7e79ffc2a87ce7ad8c0bc0c5b839ddbe438db934c7b5e0e2;
    bytes32 constant BALANCE_1_SLOT = 0xba598ef587ec4c4cf493fe15321596d40159e5c3c0cbf449810c8c6894b2e5e1;
    bytes32 constant LENDING_BALANCE_0_SLOT = 0xa186fed6f032437b8a48cdc0974abb68692f2e91b72fc868edc12eb4858e3bb1;
    bytes32 constant LENDING_BALANCE_1_SLOT = 0x73c0bdc07d4c1d10eb4a663f9c8e3bcc3df61d0f218e56d20ecb859d66dcfdf4;

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
        if (
            !(
                msg.sender == pairPoolManager || msg.sender == address(lendingPoolManager)
                    || msg.sender == address(hooks())
            )
        ) {
            revert NotPoolManager();
        }
        _;
    }

    function hooks() public view returns (IHooks hook) {
        return IPairPoolManager(pairPoolManager).hooks();
    }

    function _transform(PoolStatus memory status)
        internal
        view
        returns (uint112 newTruncatedReserve0, uint112 newTruncatedReserve1)
    {
        if (status.reserve0() > 0 && status.reserve1() > 0) {
            if (status.truncatedReserve0 == 0 || status.truncatedReserve1 == 0) {
                newTruncatedReserve0 = status.reserve0();
                newTruncatedReserve1 = status.reserve1();
            } else {
                uint256 delta = status.blockTimestampLast.getTimeElapsed();
                uint256 priceMoved = uint256(maxPriceMovePerSecond) * (delta ** 2);
                newTruncatedReserve1 = status.reserve1();
                uint256 _reserve0 = status.reserve0();
                uint256 reserve0Min = Math.mulDiv(
                    newTruncatedReserve1, status.truncatedReserve0.lowerMillion(priceMoved), status.truncatedReserve1
                );
                uint256 reserve0Max = Math.mulDiv(
                    newTruncatedReserve1, status.truncatedReserve0.upperMillion(priceMoved), status.truncatedReserve1
                );
                if (_reserve0 < reserve0Min) {
                    newTruncatedReserve0 = reserve0Min.toUint112();
                } else if (_reserve0 > reserve0Max) {
                    newTruncatedReserve0 = reserve0Max.toUint112();
                } else {
                    newTruncatedReserve0 = _reserve0.toUint112();
                }
            }
        }
    }

    function _getStatus(PoolId poolId, bool lendingIn) internal view returns (GlobalStatus memory globalStatus) {
        PoolStatus memory _status = statusStore[poolId];
        LendingStatus memory lendingStatus = LendingStatus(UQ112x112.Q112, UQ112x112.Q112);
        if (_status.key.currency1 == CurrencyLibrary.ADDRESS_ZERO) revert PairNotExists();
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        uint256 lendingGrownAmount0;
        uint256 lendingGrownAmount1;
        if (_status.blockTimestampLast != blockTS) {
            if (_status.totalMirrorReserves() > 0) {
                (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) =
                    marginFees.getBorrowRateCumulativeLast(_status);

                if (!interestClosed[poolId]) {
                    (InterestBalance memory interestStatus0,) = _updateInterest0(poolId, _status, rate0CumulativeLast);
                    if (interestStatus0.allInterest > 0) {
                        _status.mirrorReserve0 += interestStatus0.pairInterest.toUint112();
                        uint256 lendingAmount0 = interestStatus0.lendingInterest + interestStatus0.protocolInterest;
                        _status.lendingMirrorReserve0 += lendingAmount0.toUint112();
                        lendingGrownAmount0 = interestStatus0.lendingInterest;
                    }

                    (InterestBalance memory interestStatus1,) = _updateInterest1(poolId, _status, rate1CumulativeLast);
                    if (interestStatus1.allInterest > 0) {
                        _status.mirrorReserve1 += interestStatus1.pairInterest.toUint112();
                        uint256 lendingAmount1 = interestStatus1.lendingInterest + interestStatus1.protocolInterest;
                        _status.lendingMirrorReserve1 += lendingAmount1.toUint112();
                        lendingGrownAmount1 = interestStatus1.lendingInterest;
                    }
                }

                _status.rate0CumulativeLast = rate0CumulativeLast;
                _status.rate1CumulativeLast = rate1CumulativeLast;
            }

            (_status.truncatedReserve0, _status.truncatedReserve1) = _transform(_status);
            _status.blockTimestampLast = blockTS;
        }
        if (lendingIn) {
            uint256 id0 = _status.key.currency0.toTokenId(poolId);
            lendingStatus.accruesRatio0X112 = lendingPoolManager.getGrownRatioX112(id0, lendingGrownAmount0);
            uint256 id1 = _status.key.currency1.toTokenId(poolId);
            lendingStatus.accruesRatio1X112 = lendingPoolManager.getGrownRatioX112(id1, lendingGrownAmount1);
        }
        globalStatus.pairPoolStatus = _status;
        globalStatus.lendingStatus = lendingStatus;
    }

    function getStatus(PoolId poolId) public view returns (PoolStatus memory _status) {
        _status = _getStatus(poolId, false).pairPoolStatus;
    }

    function getGlobalStatus(PoolId poolId) public view returns (GlobalStatus memory _status) {
        _status = _getStatus(poolId, true);
    }

    function getReserves(PoolId poolId) external view returns (uint256 _reserve0, uint256 _reserve1) {
        PoolStatus memory status = getStatus(poolId);
        (_reserve0, _reserve1) = status.getReserves();
    }

    // given an input amount of an asset and pair reserve, returns the maximum output amount of the other asset
    function getAmountOut(PoolStatus memory status, bool zeroForOne, uint256 amountIn)
        public
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, " INSUFFICIENT_LIQUIDITY");
        fee = marginFees.dynamicFee(status, zeroForOne, amountIn, amountOut);
        uint256 amountInWithoutFee;
        (amountInWithoutFee, feeAmount) = fee.deduct(amountIn);
        uint256 numerator = amountInWithoutFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithoutFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserve, returns a required input amount of the other asset
    function getAmountIn(PoolStatus memory status, bool zeroForOne, uint256 amountOut)
        public
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        (uint256 _reserve0, uint256 _reserve1) = status.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        require(amountOut < reserveOut, "OUTPUT_AMOUNT_OVERFLOW");
        fee = marginFees.dynamicFee(status, zeroForOne, amountIn, amountOut);
        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = (reserveOut - amountOut);
        uint256 amountInWithoutFee = (numerator / denominator) + 1;
        (amountIn, feeAmount) = fee.attach(amountInWithoutFee);
    }

    function _callSet() internal {
        if (_notCallUpdate()) {
            revert UpdateBalanceGuardErrorCall();
        }

        UPDATE_BALANCE_GUARD_SLOT.asBoolean().tstore(true);
    }

    function _callUpdate() internal {
        if (_notCallSet()) {
            revert UpdateBalanceGuardErrorCall();
        }

        UPDATE_BALANCE_GUARD_SLOT.asBoolean().tstore(false);
    }

    function _notCallSet() internal view returns (bool) {
        return !UPDATE_BALANCE_GUARD_SLOT.asBoolean().tload();
    }

    function _notCallUpdate() internal view returns (bool) {
        return UPDATE_BALANCE_GUARD_SLOT.asBoolean().tload();
    }

    function _getRealBalances() internal view returns (BalanceStatus memory) {
        uint256 balance0 = BALANCE_0_SLOT.asUint256().tload();
        uint256 balance1 = BALANCE_1_SLOT.asUint256().tload();
        uint256 lendingBalance0 = LENDING_BALANCE_0_SLOT.asUint256().tload();
        uint256 lendingBalance1 = LENDING_BALANCE_1_SLOT.asUint256().tload();

        return BalanceStatus(balance0, balance1, 0, 0, lendingBalance0, lendingBalance1, 0, 0);
    }

    function _getRealBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
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
        balanceStatus.lendingBalance0 = poolManager.balanceOf(address(lendingPoolManager), key.currency0.toId());
        balanceStatus.lendingBalance1 = poolManager.balanceOf(address(lendingPoolManager), key.currency1.toId());
    }

    function _getAllBalances(PoolKey memory key) internal view returns (BalanceStatus memory balanceStatus) {
        balanceStatus = _getRealBalances(key);
        uint256 id0 = key.currency0.toTokenId(key);
        uint256 id1 = key.currency1.toTokenId(key);
        balanceStatus.mirrorBalance0 = mirrorTokenManager.balanceOf(pairPoolManager, id0);
        balanceStatus.mirrorBalance1 = mirrorTokenManager.balanceOf(pairPoolManager, id1);
        balanceStatus.lendingMirrorBalance0 = mirrorTokenManager.balanceOf(address(lendingPoolManager), id0);
        balanceStatus.lendingMirrorBalance1 = mirrorTokenManager.balanceOf(address(lendingPoolManager), id1);
    }

    function _updateInterest0(PoolId poolId, PoolStatus memory status, uint256 rate0CumulativeLast)
        internal
        view
        returns (InterestBalance memory interestStatus, uint256 interest0X112)
    {
        uint256 mirrorReserve0 = status.totalMirrorReserve0();
        if (mirrorReserve0 > 0 && rate0CumulativeLast > status.rate0CumulativeLast) {
            uint256 allInterest0 = Math.mulDiv(
                mirrorReserve0 * UQ112x112.Q112, rate0CumulativeLast, status.rate0CumulativeLast
            ) - mirrorReserve0 * UQ112x112.Q112 + interestX112Store0[poolId];
            uint256 protocolInterest = marginFees.getProtocolInterestFeeAmount(allInterest0);
            if (protocolInterest > UQ112x112.Q112) {
                allInterest0 = allInterest0 / UQ112x112.Q112;
                interestStatus.protocolInterest = protocolInterest / UQ112x112.Q112;
                allInterest0 -= interestStatus.protocolInterest;
                uint256 interest0 =
                    Math.mulDiv(allInterest0, status.reserve0(), status.reserve0() + status.lendingReserve0());
                interestStatus.allInterest = allInterest0;
                interestStatus.pairInterest = interest0;
                if (allInterest0 > interest0) {
                    interestStatus.lendingInterest = allInterest0 - interest0;
                }
            } else {
                interest0X112 = allInterest0;
            }
        }
    }

    function _updateInterest1(PoolId poolId, PoolStatus memory status, uint256 rate1CumulativeLast)
        internal
        view
        returns (InterestBalance memory interestStatus, uint256 interest1X112)
    {
        uint256 mirrorReserve1 = status.totalMirrorReserve1();
        if (mirrorReserve1 > 0 && rate1CumulativeLast > status.rate1CumulativeLast) {
            uint256 allInterest1 = Math.mulDiv(
                mirrorReserve1 * UQ112x112.Q112, rate1CumulativeLast, status.rate1CumulativeLast
            ) - mirrorReserve1 * UQ112x112.Q112 + interestX112Store1[poolId];
            uint256 protocolInterest = marginFees.getProtocolInterestFeeAmount(allInterest1);
            if (protocolInterest > UQ112x112.Q112) {
                allInterest1 = allInterest1 / UQ112x112.Q112;
                interestStatus.protocolInterest = protocolInterest / UQ112x112.Q112;
                allInterest1 -= interestStatus.protocolInterest;
                uint256 interest1 =
                    Math.mulDiv(allInterest1, status.reserve1(), status.reserve1() + status.lendingReserve1());
                interestStatus.allInterest = allInterest1;
                interestStatus.pairInterest = interest1;
                if (allInterest1 > interest1) {
                    interestStatus.lendingInterest = allInterest1 - interest1;
                }
            } else {
                interest1X112 = allInterest1;
            }
        }
    }

    function _updateInterests(address sender, PoolStatus storage status) internal {
        PoolKey memory key = status.key;
        PoolId poolId = key.toId();
        if (status.totalMirrorReserves() > 0) {
            (uint256 rate0CumulativeLast, uint256 rate1CumulativeLast) = marginFees.getBorrowRateCumulativeLast(status);
            (InterestBalance memory interestStatus0, uint256 interest0X112) =
                _updateInterest0(poolId, status, rate0CumulativeLast);
            (InterestBalance memory interestStatus1, uint256 interest1X112) =
                _updateInterest1(poolId, status, rate1CumulativeLast);
            {
                if (interest0X112 > 0) {
                    interestX112Store0[poolId] += interest0X112;
                }
                if (interest1X112 > 0) {
                    interestX112Store1[poolId] += interest1X112;
                }
                if (interestStatus0.allInterest > 0) {
                    interestX112Store0[poolId] = 0;
                    uint256 cPoolId0 = status.key.currency0.toTokenId(poolId);
                    if (interestStatus0.pairInterest > 0) {
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
                    if (interestStatus0.protocolInterest > 0) {
                        status.lendingMirrorReserve0 += interestStatus0.protocolInterest.toUint112();
                        lendingPoolManager.updateProtocolInterests(
                            sender, poolId, key.currency0, interestStatus0.protocolInterest
                        );
                    }
                }

                if (interestStatus1.allInterest > 0) {
                    interestX112Store1[poolId] = 0;
                    uint256 cPoolId1 = status.key.currency1.toTokenId(poolId);
                    if (interestStatus1.pairInterest > 0) {
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
                    if (interestStatus1.protocolInterest > 0) {
                        status.lendingMirrorReserve1 += interestStatus1.protocolInterest.toUint112();
                        lendingPoolManager.updateProtocolInterests(
                            sender, poolId, key.currency1, interestStatus1.protocolInterest
                        );
                    }
                }
            }

            status.rate0CumulativeLast = rate0CumulativeLast;
            status.rate1CumulativeLast = rate1CumulativeLast;
        }

        lendingPoolManager.sync(poolId, status);
    }

    // ******************** OWNER CALL ********************

    function setFeeStatus(PoolId poolId, uint24 _marginFee) external onlyOwner {
        statusStore[poolId].marginFee = _marginFee;
    }

    function setMarginFees(address _marginFees) external onlyOwner {
        if (_marginFees != address(0)) {
            emit MarginFeesChanged(address(marginFees), _marginFees);
            marginFees = IMarginFees(_marginFees);
        }
    }

    function setMaxPriceMovePerSecond(uint32 _maxPriceMovePerSecond) external onlyOwner {
        if (_maxPriceMovePerSecond > 0) {
            maxPriceMovePerSecond = _maxPriceMovePerSecond;
        }
    }

    function setInterestClosed(PoolId poolId, bool _closed) external onlyOwner {
        PoolStatus storage status = statusStore[poolId];
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (status.blockTimestampLast != blockTS) {
            (status.truncatedReserve0, status.truncatedReserve1) = _transform(status);
            status.blockTimestampLast = blockTS;
        }
        interestClosed[poolId] = _closed;
    }

    // ******************** POOL_MANAGER CALL ********************

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

    function setBalances(address sender, PoolId poolId) public onlyPoolManager returns (PoolStatus memory) {
        _callSet();
        PoolStatus storage status = statusStore[poolId];
        uint32 blockTS = uint32(block.timestamp % 2 ** 32);
        if (status.blockTimestampLast != blockTS) {
            if (!interestClosed[poolId]) {
                _updateInterests(sender, status);
            }

            (status.truncatedReserve0, status.truncatedReserve1) = _transform(status);
            status.blockTimestampLast = blockTS;
        }

        BalanceStatus memory balanceStatus = _getRealBalances(status.key);
        BALANCE_0_SLOT.asUint256().tstore(balanceStatus.balance0);
        BALANCE_1_SLOT.asUint256().tstore(balanceStatus.balance1);
        LENDING_BALANCE_0_SLOT.asUint256().tstore(balanceStatus.lendingBalance0);
        LENDING_BALANCE_1_SLOT.asUint256().tstore(balanceStatus.lendingBalance1);
        return status;
    }

    function update(PoolId poolId) public onlyPoolManager {
        PoolStatus storage status = statusStore[poolId];

        BalanceStatus memory beforeStatus = _getRealBalances();
        BalanceStatus memory afterStatus = _getAllBalances(status.key);
        status.realReserve0 = status.realReserve0.add(afterStatus.balance0).sub(beforeStatus.balance0);
        status.realReserve1 = status.realReserve1.add(afterStatus.balance1).sub(beforeStatus.balance1);
        status.mirrorReserve0 = afterStatus.mirrorBalance0.toUint112();
        status.mirrorReserve1 = afterStatus.mirrorBalance1.toUint112();
        status.lendingRealReserve0 =
            status.lendingRealReserve0.add(afterStatus.lendingBalance0).sub(beforeStatus.lendingBalance0);
        status.lendingRealReserve1 =
            status.lendingRealReserve1.add(afterStatus.lendingBalance1).sub(beforeStatus.lendingBalance1);
        status.lendingMirrorReserve0 = afterStatus.lendingMirrorBalance0.toUint112();
        status.lendingMirrorReserve1 = afterStatus.lendingMirrorBalance1.toUint112();
        if (status.truncatedReserve0 == 0) {
            status.truncatedReserve0 = status.reserve0();
        }
        if (status.truncatedReserve1 == 0) {
            status.truncatedReserve1 = status.reserve1();
        }

        lendingPoolManager.sync(poolId, status);
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

    function updateSwapProtocolFees(Currency currency, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 restAmount)
    {
        uint256 protocolFees = marginFees.getProtocolSwapFeeAmount(amount);
        protocolFeesAccrued[currency] += protocolFees;
        restAmount = amount - protocolFees;
    }

    function updateMarginProtocolFees(Currency currency, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 restAmount)
    {
        uint256 protocolFees = marginFees.getProtocolMarginFeeAmount(amount);
        protocolFeesAccrued[currency] += protocolFees;
        restAmount = amount - protocolFees;
    }

    function collectProtocolFees(Currency currency, uint256 amount)
        external
        onlyPoolManager
        returns (uint256 amountCollected)
    {
        amountCollected = (amount == 0) ? protocolFeesAccrued[currency] : amount;
        protocolFeesAccrued[currency] -= amountCollected;
    }
}
