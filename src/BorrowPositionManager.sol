// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {IBorrowPositionManager} from "./interfaces/IBorrowPositionManager.sol";
import {IPairPoolManager} from "./interfaces/IPairPoolManager.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {BorrowPosition, BorrowPositionVo} from "./types/BorrowPosition.sol";
import {BurnParams} from "./types/BurnParams.sol";
import {PoolStatus} from "./types/PoolStatus.sol";
import {BorrowParams} from "./types/BorrowParams.sol";
import {MarginParams} from "./types/MarginParams.sol";
import {ReleaseParams} from "./types/ReleaseParams.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";

contract BorrowPositionManager is IBorrowPositionManager, ERC721, Owned {
    using CurrencyUtils for Currency;
    using CurrencyLibrary for Currency;
    using UQ112x112 for uint224;
    using PriceMath for uint224;
    using TimeUtils for uint32;

    error PairNotExists();
    error PositionLiquidated();
    error MarginTransferFailed(uint256 amount);
    error InsufficientAmount(uint256 amount);
    error InsufficientBorrowReceived();

    event Mint(PoolId indexed poolId, address indexed sender, address indexed to, uint256 positionId);
    event Burn(PoolId indexed poolId, address indexed sender, uint256 positionId, uint8 burnType);
    event Borrow(
        PoolId indexed poolId,
        address indexed owner,
        uint256 positionId,
        uint256 marginAmount,
        uint256 borrowAmount,
        bool marginForOne
    );
    event RepayClose(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 releaseMarginAmount,
        uint256 repayAmount,
        uint256 repayRawAmount,
        int256 pnlAmount
    );
    event Liquidate(
        PoolId indexed poolId, address indexed sender, uint256 positionId, uint256 marginAmount, uint256 borrowAmount
    );

    enum BurnType {
        CLOSE,
        LIQUIDATE
    }

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 private _nextId = 1;
    uint24 public minMarginLevel = 1170000; // 117%
    IPairPoolManager private hook;
    IMarginChecker public checker;

    mapping(uint256 => BorrowPosition) private _positions;
    mapping(address => uint256) private _hookPositions;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _borrowPositions;

    constructor(address initialOwner, IMarginChecker _checker)
        ERC721("LIKWIDBorrowPositionManager", "LBPM")
        Owned(initialOwner)
    {
        checker = _checker;
    }

    function _burnPosition(uint256 positionId, BurnType burnType) internal {
        // _burn(positionId);
        BorrowPosition memory _position = _positions[positionId];
        delete _borrowPositions[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        delete _positions[positionId];
        emit Burn(_position.poolId, msg.sender, positionId, uint8(burnType));
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    modifier onlyMargin() {
        require(msg.sender == address(hook.poolManager()) || msg.sender == address(this), "ONLY_MARGIN");
        _;
    }

    function transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "TRANSFER_FAILED");
    }

    /// @inheritdoc IBorrowPositionManager
    function getHook() external view returns (address _hook) {
        _hook = address(hook);
    }

    /// @inheritdoc IBorrowPositionManager
    function getPosition(uint256 positionId) public view returns (BorrowPosition memory _position) {
        _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast =
                hook.marginFees().getBorrowRateCumulativeLast(address(hook), _position.poolId, _position.marginForOne);
            _position.borrowAmount = uint128(uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast);
            _position.rateCumulativeLast = rateLast;
        }
    }

    function _estimatePNL(BorrowPosition memory _position, uint256 closeMillionth)
        internal
        view
        returns (int256 pnlAmount)
    {
        if (_position.borrowAmount == 0) {
            return 0;
        }
        uint256 repayAmount = uint256(_position.borrowAmount) * closeMillionth / ONE_MILLION;
        uint256 releaseAmount = hook.getAmountOut(_position.poolId, _position.marginForOne, repayAmount);
        uint256 releaseTotal = uint256(_position.marginAmount) * closeMillionth / ONE_MILLION;
        pnlAmount = int256(releaseTotal) - int256(releaseAmount);
    }

    function getPositions(uint256[] calldata positionIds) external view returns (BorrowPositionVo[] memory _position) {
        _position = new BorrowPositionVo[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            _position[i].position = getPosition(positionIds[i]);
            _position[i].pnl = _estimatePNL(_position[i].position, ONE_MILLION);
        }
    }

    function getPositionId(PoolId poolId, bool marginForOne, address owner)
        external
        view
        returns (uint256 _positionId)
    {
        _positionId = _borrowPositions[poolId][marginForOne][owner];
    }

    function checkMinMarginLevel(MarginParams memory params, PoolStatus memory _status)
        internal
        view
        returns (bool valid)
    {
        (uint256 reserve0, uint256 reserve1) =
            (_status.realReserve0 + _status.mirrorReserve0, _status.realReserve1 + _status.mirrorReserve1);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            params.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 debtAmount = reserveMargin * params.borrowAmount / (reserveBorrow - params.borrowAmount) + 1;
        valid = params.marginAmount >= debtAmount * minMarginLevel / ONE_MILLION;
    }

    /// @inheritdoc IBorrowPositionManager
    function getMarginMax(PoolId poolId, bool marginForOne)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        PoolStatus memory status = hook.getStatus(poolId);
        (uint256 _totalSupply, uint256 retainSupply0, uint256 retainSupply1) =
            hook.marginLiquidity().getPoolSupplies(address(hook), poolId);
        uint256 borrowReserve0 = (_totalSupply - retainSupply0) * status.realReserve0 / _totalSupply;
        uint256 borrowReserve1 = (_totalSupply - retainSupply1) * status.realReserve1 / _totalSupply;
        uint256 borrowMaxAmount = (marginForOne ? borrowReserve0 : borrowReserve1);
        if (borrowMaxAmount > 1000) {
            borrowAmount = borrowMaxAmount - 1000;
        } else {
            borrowAmount = 0;
        }
        if (borrowAmount > 0) {
            marginMax = hook.getAmountIn(poolId, !marginForOne, borrowAmount);
        }
    }

    /// @inheritdoc IBorrowPositionManager
    function borrow(BorrowParams memory bParams) external payable ensure(bParams.deadline) returns (uint256, uint256) {
        PoolStatus memory _status = hook.getStatus(bParams.poolId);
        Currency marginToken = bParams.marginForOne ? _status.key.currency1 : _status.key.currency0;
        bool success = marginToken.transfer(msg.sender, address(this), bParams.marginAmount);
        if (!success) revert MarginTransferFailed(bParams.marginAmount);
        uint256 positionId = _borrowPositions[bParams.poolId][bParams.marginForOne][bParams.recipient];
        MarginParams memory params = MarginParams({
            poolId: bParams.poolId,
            marginForOne: bParams.marginForOne,
            leverage: 0,
            marginAmount: bParams.marginAmount,
            marginTotal: 0,
            borrowAmount: bParams.borrowAmount,
            borrowMaxAmount: bParams.borrowMaxAmount,
            recipient: bParams.recipient,
            deadline: bParams.deadline
        });
        params = hook.margin{value: msg.value}(msg.sender, params);
        uint256 rateLast = params.marginForOne ? _status.rate0CumulativeLast : _status.rate1CumulativeLast;
        if (params.borrowMaxAmount > 0 && params.borrowAmount > params.borrowMaxAmount) {
            revert InsufficientBorrowReceived();
        }
        if (!checkMinMarginLevel(params, _status)) revert InsufficientAmount(params.marginAmount);
        if (positionId == 0) {
            _mint(params.recipient, (positionId = _nextId++));
            emit Mint(params.poolId, msg.sender, params.recipient, positionId);
            BorrowPosition memory _position = BorrowPosition({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                marginAmount: uint128(params.marginAmount),
                borrowAmount: uint128(params.borrowAmount),
                rawBorrowAmount: uint128(params.borrowAmount),
                rateCumulativeLast: rateLast
            });
            _borrowPositions[params.poolId][params.marginForOne][params.recipient] = positionId;
            _positions[positionId] = _position;
        } else {
            BorrowPosition storage _position = _positions[positionId];
            uint256 borrowAmount = uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast;
            _position.marginAmount += uint128(params.marginAmount);
            _position.rawBorrowAmount += uint128(params.borrowAmount);
            _position.borrowAmount = uint128(borrowAmount + params.borrowAmount);
            _position.rateCumulativeLast = rateLast;
        }
        emit Borrow(
            params.poolId, params.recipient, positionId, params.marginAmount, params.borrowAmount, params.marginForOne
        );
        return (positionId, params.borrowAmount);
    }

    function release(
        uint256 positionId,
        Currency marginToken,
        uint256 repayAmount,
        uint256 borrowAmount,
        uint256 repayRawAmount,
        int256 pnlAmount,
        uint256 rateLast
    ) internal {
        BorrowPosition storage _position = _positions[positionId];
        (bool liquidated,) = checker.checkLiquidate(_position, address(hook));
        if (liquidated) revert PositionLiquidated();
        // update position
        _position.borrowAmount = uint128(borrowAmount - repayAmount);
        uint256 releaseMargin = uint256(_position.marginAmount) * repayAmount / borrowAmount;
        bool success = marginToken.transfer(address(this), msg.sender, releaseMargin);
        require(success, "RELEASE_TRANSFER_ERR");
        emit RepayClose(_position.poolId, msg.sender, positionId, releaseMargin, repayAmount, repayRawAmount, pnlAmount);
        if (_position.borrowAmount == 0) {
            _burnPosition(positionId, BurnType.CLOSE);
        } else {
            _position.marginAmount -= uint128(releaseMargin);
            _position.rawBorrowAmount -= uint128(repayRawAmount);
            _position.rateCumulativeLast = rateLast;
        }
    }

    /// @inheritdoc IBorrowPositionManager
    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline) external payable ensure(deadline) {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        BorrowPosition memory _position = getPosition(positionId);
        PoolStatus memory _status = hook.getStatus(_position.poolId);
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        if (repayAmount > _position.borrowAmount) {
            repayAmount = _position.borrowAmount;
        }
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            rawBorrowAmount: 0,
            repayAmount: repayAmount,
            releaseAmount: 0,
            deadline: deadline
        });
        params.rawBorrowAmount = uint256(_position.rawBorrowAmount) * repayAmount / _position.borrowAmount;
        int256 pnlAmount = _estimatePNL(_position, repayAmount * ONE_MILLION / _position.borrowAmount);
        uint256 sendValue = Math.min(repayAmount, msg.value);
        hook.release{value: sendValue}(params);
        release(
            positionId,
            marginToken,
            repayAmount,
            _position.borrowAmount,
            params.rawBorrowAmount,
            pnlAmount,
            _position.rateCumulativeLast
        );
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
    }

    function liquidateBurn(uint256 positionId, bytes calldata signature) external returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, positionId, signature), "AUTH_ERROR");
        BorrowPosition memory _position = _positions[positionId];
        BurnParams memory params = BurnParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            positionIds: new uint256[](1),
            signature: signature
        });
        params.positionIds[0] = positionId;
        return liquidateBurn(params);
    }

    function liquidateProfit(uint256 marginAmount, BurnParams memory params)
        internal
        returns (Currency marginToken, uint256 profit, uint256 protocolProfit)
    {
        (uint24 callerProfitMillion, uint24 protocolProfitMillion) = checker.getProfitMillions();
        PoolStatus memory _status = hook.getStatus(params.poolId);
        marginToken = params.marginForOne ? _status.key.currency1 : _status.key.currency0;
        if (callerProfitMillion > 0) {
            profit = marginAmount * callerProfitMillion / ONE_MILLION;
            marginToken.transfer(address(this), msg.sender, profit);
        }
        if (protocolProfitMillion > 0) {
            address feeTo = hook.marginFees().feeTo();
            if (feeTo != address(0)) {
                protocolProfit = marginAmount * protocolProfitMillion / ONE_MILLION;
                marginToken.transfer(address(this), feeTo, protocolProfit);
            }
        }
    }

    function liquidateBurn(BurnParams memory params) public returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, 0, params.signature), "AUTH_ERROR");
        BorrowPosition[] memory inPositions = new BorrowPosition[](params.positionIds.length);
        for (uint256 i = 0; i < params.positionIds.length; i++) {
            inPositions[i] = _positions[params.positionIds[i]];
        }
        (bool[] memory liquidatedList, uint256[] memory borrowAmountList) =
            checker.checkLiquidate(params.poolId, params.marginForOne, address(hook), inPositions);

        uint256 releaseAmount;
        uint256 rawBorrowAmount;
        uint256 borrowAmount;
        uint256 liquidateValue;
        {
            uint256 marginAmount;
            for (uint256 i = 0; i < params.positionIds.length; i++) {
                if (liquidatedList[i]) {
                    uint256 positionId = params.positionIds[i];
                    BorrowPosition memory _position = inPositions[i];
                    marginAmount += _position.marginAmount;
                    borrowAmount += borrowAmountList[i];
                    rawBorrowAmount += _position.rawBorrowAmount;
                    emit Liquidate(params.poolId, msg.sender, positionId, _position.marginAmount, borrowAmountList[i]);
                    _burnPosition(positionId, BurnType.LIQUIDATE);
                }
            }
            if (marginAmount == 0) {
                return profit;
            }
            uint256 protocolProfit;
            Currency marginToken;
            (marginToken, profit, protocolProfit) = liquidateProfit(marginAmount, params);
            releaseAmount = marginAmount - profit - protocolProfit;
            if (marginToken == CurrencyLibrary.ADDRESS_ZERO) {
                liquidateValue = releaseAmount;
            } else {
                bool success = marginToken.approve(address(hook), releaseAmount);
                require(success, "APPROVE_ERR");
            }
        }
        if (releaseAmount > 0) {
            ReleaseParams memory releaseParams = ReleaseParams({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                payer: address(this),
                rawBorrowAmount: rawBorrowAmount,
                releaseAmount: releaseAmount,
                repayAmount: borrowAmount,
                deadline: block.timestamp + 1000
            });
            hook.release{value: liquidateValue}(releaseParams);
        }
    }

    function liquidateCall(uint256 positionId, bytes calldata signature) external payable returns (uint256 profit) {
        require(checker.checkValidity(msg.sender, positionId, signature), "AUTH_ERROR");
        (bool liquidated, uint256 borrowAmount) = checker.checkLiquidate(address(this), positionId);
        if (!liquidated) {
            return profit;
        }
        BorrowPosition memory _position = _positions[positionId];
        PoolStatus memory _status = hook.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        uint256 liquidateValue = 0;
        if (borrowToken == CurrencyLibrary.ADDRESS_ZERO) {
            liquidateValue = borrowAmount;
        }
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            rawBorrowAmount: _position.rawBorrowAmount,
            repayAmount: borrowAmount,
            releaseAmount: 0,
            deadline: block.timestamp + 1000
        });
        hook.release{value: liquidateValue}(params);
        profit = _position.marginAmount;
        marginToken.transfer(address(this), msg.sender, profit);
        if (msg.value > liquidateValue) {
            transferNative(msg.sender, msg.value - liquidateValue);
        }
        emit Liquidate(_position.poolId, msg.sender, positionId, _position.marginAmount, borrowAmount);
        _burnPosition(positionId, BurnType.LIQUIDATE);
    }

    receive() external payable onlyMargin {}

    // ******************** OWNER CALL ********************

    function setHook(address _hook) external onlyOwner {
        hook = IPairPoolManager(_hook);
    }

    function setMinMarginLevel(uint24 _minMarginLevel) external onlyOwner {
        minMarginLevel = _minMarginLevel;
    }

    function setMarginChecker(address _checker) external onlyOwner {
        checker = IMarginChecker(_checker);
    }
}
