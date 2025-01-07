// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
// Local
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {IMarginOracleReader} from "./interfaces/IMarginOracleReader.sol";
import {IMarginChecker} from "./interfaces/IMarginChecker.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {HookStatus} from "./types/HookStatus.sol";
import {MarginParams, ReleaseParams} from "./types/MarginParams.sol";
import {Math} from "./libraries/Math.sol";
import {UQ112x112} from "./libraries/UQ112x112.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {TimeUtils} from "./libraries/TimeUtils.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned {
    using CurrencyUtils for Currency;
    using CurrencyLibrary for Currency;
    using UQ112x112 for uint224;
    using PriceMath for uint224;
    using TimeUtils for uint32;

    error PairNotExists();
    error Liquidated();
    error MarginTransferFailed(uint256 amount);
    error InsufficientAmount(uint256 amount);
    error InsufficientBorrowReceived();

    event Mint(PoolId indexed poolId, address indexed sender, address indexed to, uint256 positionId);
    event Burn(PoolId indexed poolId, address indexed sender, uint256 positionId);
    event Margin(
        PoolId indexed poolId,
        address indexed owner,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount,
        bool marginForOne
    );
    event Repay(PoolId indexed poolId, address indexed sender, uint256 positionId, uint256 repayAmount);
    event Close(
        PoolId indexed poolId, address indexed sender, uint256 positionId, uint256 releaseAmount, uint256 repayAmount
    );
    event Modify(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount
    );

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 public constant ONE_BILLION = 10 ** 9;
    uint256 public constant YEAR_SECONDS = 365 * 24 * 3600;
    uint256 private _nextId = 1;
    uint256 public marginMinAmount = 0.1 ether;
    IMarginHookManager private hook;
    IMarginChecker public checker;
    address public marginOracle;

    mapping(uint256 => MarginPosition) private _positions;
    mapping(address => uint256) private _hookPositions;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _borrowPositions;

    constructor(address initialOwner, IMarginChecker _checker)
        ERC721("LIKWIDMarginPositionManager", "LMPM")
        Owned(initialOwner)
    {
        checker = _checker;
    }

    function _burnPosition(uint256 positionId) internal {
        // _burn(positionId);
        MarginPosition memory _position = _positions[positionId];
        delete _borrowPositions[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        delete _positions[positionId];
        emit Burn(_position.poolId, msg.sender, positionId);
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

    function setHook(address _hook) external onlyOwner {
        hook = IMarginHookManager(_hook);
    }

    function getHook() external view returns (address _hook) {
        _hook = address(hook);
    }

    function setMarginOracle(address _oracle) external onlyOwner {
        marginOracle = _oracle;
    }

    function setMarginChecker(address _checker) external onlyOwner {
        checker = IMarginChecker(_checker);
    }

    function getPosition(uint256 positionId) public view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast =
                hook.marginFees().getBorrowRateCumulativeLast(address(hook), _position.poolId, _position.marginForOne);
            _position.borrowAmount = uint128(uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast);
            _position.rateCumulativeLast = rateLast;
        }
    }

    function getPositionId(PoolId poolId, bool marginForOne, address owner)
        external
        view
        returns (uint256 _positionId)
    {
        _positionId = _borrowPositions[poolId][marginForOne][owner];
    }

    function checkAmount(Currency currency, address payer, address recipient, uint256 amount)
        internal
        returns (bool valid)
    {
        if (currency.isAddressZero()) {
            valid = msg.value >= amount;
        } else {
            if (payer != address(this)) {
                valid = IERC20Minimal(Currency.unwrap(currency)).allowance(payer, recipient) >= amount;
            } else {
                valid = IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(this)) >= amount;
            }
        }
    }

    function getMarginTotal(PoolId poolId, bool marginForOne, uint24 leverage, uint256 marginAmount)
        external
        view
        returns (uint256 marginWithoutFee, uint256 borrowAmount)
    {
        HookStatus memory status = hook.getStatus(poolId);
        uint256 marginTotal = marginAmount * leverage;
        borrowAmount = hook.getAmountIn(poolId, marginForOne, marginTotal);
        marginWithoutFee = marginTotal * (ONE_MILLION - status.feeStatus.marginFee) / ONE_MILLION;
    }

    function getMarginMax(PoolId poolId, bool marginForOne, uint24 leverage)
        external
        view
        returns (uint256 marginMax, uint256 borrowAmount)
    {
        HookStatus memory status = hook.getStatus(poolId);
        (uint256 _totalSupply, uint256 retainSupply0, uint256 retainSupply1) =
            hook.marginLiquidity().getPoolSupplies(address(hook), poolId);
        uint256 marginReserve0 = (_totalSupply - retainSupply0) * status.realReserve0 / _totalSupply;
        uint256 marginReserve1 = (_totalSupply - retainSupply1) * status.realReserve1 / _totalSupply;
        uint256 marginMaxTotal = (marginForOne ? marginReserve1 : marginReserve0);
        if (marginMaxTotal > 1000) {
            marginMaxTotal -= 1000;
        }
        borrowAmount = hook.getAmountIn(poolId, marginForOne, marginMaxTotal);
        marginMax = marginMaxTotal / leverage;
    }

    function margin(MarginParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        HookStatus memory _status = hook.getStatus(params.poolId);
        Currency marginToken = params.marginForOne ? _status.key.currency1 : _status.key.currency0;
        if (!checkAmount(marginToken, msg.sender, address(this), params.marginAmount)) {
            revert InsufficientAmount(params.marginAmount);
        }
        bool success = marginToken.transfer(msg.sender, address(this), params.marginAmount);
        if (!success) revert MarginTransferFailed(params.marginAmount);
        uint256 positionId = _borrowPositions[params.poolId][params.marginForOne][params.recipient];
        params = hook.margin(params);
        uint256 rateLast = hook.marginFees().getBorrowRateCumulativeLast(_status, params.marginForOne);
        if (params.borrowAmount < params.borrowMinAmount) revert InsufficientBorrowReceived();
        if (positionId == 0) {
            _mint(params.recipient, (positionId = _nextId++));
            emit Mint(params.poolId, msg.sender, params.recipient, positionId);
            _positions[positionId] = MarginPosition({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                marginAmount: uint128(params.marginAmount),
                marginTotal: uint128(params.marginTotal),
                borrowAmount: uint128(params.borrowAmount),
                rawBorrowAmount: uint128(params.borrowAmount),
                rateCumulativeLast: rateLast
            });
            _borrowPositions[params.poolId][params.marginForOne][params.recipient] = positionId;
        } else {
            MarginPosition storage _position = _positions[positionId];
            (bool liquidated,) = _checkLiquidate(_position);
            require(!liquidated, "liquidated");
            _position.marginAmount += uint128(params.marginAmount);
            _position.marginTotal += uint128(params.marginTotal);
            _position.rawBorrowAmount += uint128(params.borrowAmount);
            _position.borrowAmount =
                uint128(uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast + params.borrowAmount);
            _position.rateCumulativeLast = rateLast;
        }
        emit Margin(
            params.poolId,
            params.recipient,
            positionId,
            params.marginAmount,
            params.marginTotal,
            params.borrowAmount,
            params.marginForOne
        );
        return (positionId, params.borrowAmount);
    }

    function release(
        uint256 positionId,
        Currency marginToken,
        uint256 repayAmount,
        uint256 borrowAmount,
        uint256 repayRawAmount,
        uint256 rateLast
    ) internal {
        MarginPosition storage _position = _positions[positionId];
        (bool liquidated,) = _checkLiquidate(_position);
        require(!liquidated, "liquidated");
        // update position
        _position.borrowAmount = uint128(borrowAmount - repayAmount);
        uint256 releaseMargin = uint256(_position.marginAmount) * repayAmount / borrowAmount;
        uint256 releaseTotal = uint256(_position.marginTotal) * repayAmount / borrowAmount;
        bool success = marginToken.transfer(address(this), msg.sender, releaseMargin + releaseTotal);
        require(success, "RELEASE_TRANSFER_ERR");
        if (_position.borrowAmount == 0) {
            _burnPosition(positionId);
        } else {
            _position.marginAmount -= uint128(releaseMargin);
            _position.marginTotal -= uint128(releaseTotal);
            _position.rawBorrowAmount -= uint128(repayRawAmount);
            _position.rateCumulativeLast = rateLast;
        }
    }

    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline) external payable ensure(deadline) {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition memory _position = getPosition(positionId);
        HookStatus memory _status = hook.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        if (!checkAmount(borrowToken, msg.sender, address(hook), repayAmount)) {
            revert InsufficientAmount(repayAmount);
        }
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
        uint256 sendValue = Math.min(repayAmount, msg.value);
        hook.release{value: sendValue}(params);
        release(
            positionId,
            marginToken,
            repayAmount,
            _position.borrowAmount,
            params.rawBorrowAmount,
            _position.rateCumulativeLast
        );
        if (msg.value > sendValue) {
            transferNative(msg.sender, msg.value - sendValue);
        }
        emit Repay(_position.poolId, msg.sender, positionId, repayAmount);
    }

    function estimatePNL(uint256 positionId, uint256 repayMillionth) external view returns (int256 pnlMinAmount) {
        MarginPosition memory _position = getPosition(positionId);
        uint256 repayAmount = uint256(_position.borrowAmount) * repayMillionth / ONE_MILLION;
        uint256 releaseAmount = hook.getAmountIn(_position.poolId, !_position.marginForOne, repayAmount);
        uint256 sendValue = uint256(_position.marginAmount + _position.marginTotal) * repayMillionth / ONE_MILLION;
        pnlMinAmount = int256(sendValue) - int256(releaseAmount);
    }

    function close(
        uint256 positionId,
        uint256 releaseMargin,
        uint256 releaseTotal,
        uint256 repayAmount,
        uint256 borrowAmount,
        uint256 repayRawAmount,
        uint256 rateLast
    ) internal {
        // update position
        MarginPosition storage sPosition = _positions[positionId];
        sPosition.borrowAmount = uint128(borrowAmount - repayAmount);

        if (sPosition.borrowAmount == 0) {
            _burnPosition(positionId);
        } else {
            sPosition.marginAmount -= uint128(releaseMargin);
            sPosition.marginTotal -= uint128(releaseTotal);
            sPosition.rawBorrowAmount -= uint128(repayRawAmount);
            sPosition.rateCumulativeLast = rateLast;
        }
    }

    function close(uint256 positionId, uint256 repayMillionth, int256 pnlMinAmount, uint256 deadline)
        external
        payable
        ensure(deadline)
    {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        require(repayMillionth <= ONE_MILLION, "MILLIONTH_ERROR");
        MarginPosition memory _position = getPosition(positionId);
        HookStatus memory _status = hook.getStatus(_position.poolId);
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: address(this),
            rawBorrowAmount: 0,
            repayAmount: 0,
            releaseAmount: 0,
            deadline: deadline
        });
        params.repayAmount = uint256(_position.borrowAmount) * repayMillionth / ONE_MILLION;
        params.releaseAmount = hook.getAmountIn(_position.poolId, !_position.marginForOne, params.repayAmount);
        uint256 releaseMargin = uint256(_position.marginAmount) * repayMillionth / ONE_MILLION;
        uint256 releaseTotal = uint256(_position.marginTotal) * repayMillionth / ONE_MILLION;
        uint256 userMarginAmount;
        if (releaseMargin + releaseTotal >= params.releaseAmount) {
            require(
                pnlMinAmount < int256(releaseMargin + releaseTotal) - int256(params.releaseAmount),
                "InsufficientOutputReceived"
            );
            marginToken.transfer(address(this), msg.sender, releaseMargin + releaseTotal - params.releaseAmount);
        } else {
            uint256 marginAmount = uint256(_position.marginAmount) * (ONE_MILLION - repayMillionth) / ONE_MILLION;
            if (releaseMargin + releaseTotal + marginAmount >= params.releaseAmount) {
                require(
                    pnlMinAmount > int256(releaseMargin + releaseTotal) - int256(params.releaseAmount),
                    "InsufficientOutputReceived"
                );
                userMarginAmount = params.releaseAmount - (releaseMargin + releaseTotal);
            } else {
                // liquidated
                revert Liquidated();
            }
        }
        params.rawBorrowAmount = uint256(_position.rawBorrowAmount) * params.repayAmount / _position.borrowAmount;
        if (marginToken == CurrencyLibrary.ADDRESS_ZERO) {
            hook.release{value: params.releaseAmount}(params);
        } else {
            bool success = marginToken.approve(address(hook), params.releaseAmount);
            require(success, "APPROVE_ERR");
            hook.release(params);
        }
        close(
            positionId,
            releaseMargin + userMarginAmount,
            releaseTotal,
            params.repayAmount,
            _position.borrowAmount,
            params.rawBorrowAmount,
            _position.rateCumulativeLast
        );
        emit Close(_position.poolId, msg.sender, positionId, params.releaseAmount, params.repayAmount);
    }

    function _checkLiquidate(MarginPosition memory _position)
        private
        view
        returns (bool liquidated, uint256 amountNeed)
    {
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast =
                hook.marginFees().getBorrowRateCumulativeLast(address(hook), _position.poolId, _position.marginForOne);
            uint256 borrowAmount = uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast;
            if (marginOracle == address(0)) {
                (uint256 reserve0, uint256 reserve1) = hook.getReserves(_position.poolId);
                (uint256 reserveBorrow, uint256 reserveMargin) =
                    _position.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
                amountNeed = reserveMargin * borrowAmount / reserveBorrow;
            } else {
                (uint224 reserves,) = IMarginOracleReader(marginOracle).observeNow(_position.poolId, address(hook));
                (uint256 reserveBorrow, uint256 reserveMargin) = _position.marginForOne
                    ? (reserves.getReverse0(), reserves.getReverse1())
                    : (reserves.getReverse1(), reserves.getReverse0());
                amountNeed = reserveMargin * borrowAmount / reserveBorrow;
            }

            uint24 marginLevel = hook.marginFees().getMarginLevel(address(hook), _position.poolId);
            liquidated =
                amountNeed > uint256(_position.marginAmount) * marginLevel / ONE_MILLION + _position.marginTotal;
        }
    }

    function checkLiquidate(uint256 positionId) public view returns (bool liquidated, uint256 releaseAmount) {
        MarginPosition memory _position = _positions[positionId];
        uint256 amountNeed;
        (liquidated, amountNeed) = _checkLiquidate(_position);
        releaseAmount = Math.min(amountNeed, _position.marginAmount + _position.marginTotal);
    }

    function liquidateBurn(uint256 positionId, bytes calldata signature) external returns (uint256 profit) {
        require(checker.checkLiquidate(msg.sender, positionId, signature), "AUTH_ERROR");
        (bool liquidated, uint256 releaseAmount) = checkLiquidate(positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];
        HookStatus memory _status = hook.getStatus(_position.poolId);
        uint256 liquidateValue = 0;
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        if (marginToken == CurrencyLibrary.ADDRESS_ZERO) {
            liquidateValue = releaseAmount;
        } else {
            bool success = marginToken.approve(address(hook), releaseAmount);
            require(success, "APPROVE_ERR");
        }
        ReleaseParams memory params = ReleaseParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: address(this),
            rawBorrowAmount: _position.rawBorrowAmount,
            releaseAmount: releaseAmount,
            repayAmount: _position.borrowAmount,
            deadline: block.timestamp + 1000
        });
        hook.release{value: liquidateValue}(params);
        profit = _position.marginAmount + _position.marginTotal - releaseAmount;
        if (profit > 0) {
            marginToken.transfer(address(this), msg.sender, profit);
        }
        _burnPosition(positionId);
    }

    function liquidateCall(uint256 positionId, bytes calldata signature) external payable returns (uint256 profit) {
        require(checker.checkLiquidate(msg.sender, positionId, signature), "AUTH_ERROR");
        (bool liquidated,) = checkLiquidate(positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];
        HookStatus memory _status = hook.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        uint256 rateLast = hook.marginFees().getBorrowRateCumulativeLast(_status, _position.marginForOne);
        uint256 borrowAmount = uint256(_position.borrowAmount) * rateLast / _position.rateCumulativeLast;
        if (!checkAmount(borrowToken, msg.sender, address(hook), borrowAmount)) {
            revert InsufficientAmount(borrowAmount);
        }
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
        profit = _position.marginAmount + _position.marginTotal;
        marginToken.transfer(address(this), msg.sender, profit);
        if (msg.value > liquidateValue) {
            transferNative(msg.sender, msg.value - liquidateValue);
        }
        _burnPosition(positionId);
    }

    function getMaxDecrease(uint256 positionId) external view returns (uint256 maxAmount) {
        MarginPosition memory _position = getPosition(positionId);
        maxAmount = _getMaxDecrease(_position);
    }

    function _getMaxDecrease(MarginPosition memory _position) internal view returns (uint256 maxAmount) {
        (uint256 reserve0, uint256 reserve1) = hook.getReserves(_position.poolId);
        (uint256 reserveBorrow, uint256 reserveMargin) =
            _position.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 debtAmount = reserveMargin * _position.borrowAmount / reserveBorrow;
        if (debtAmount > _position.marginTotal) {
            uint256 newMarginAmount = (debtAmount - _position.marginTotal) * 1000 / 800;
            if (newMarginAmount < _position.marginAmount) {
                maxAmount = _position.marginAmount - newMarginAmount;
            }
        } else {
            maxAmount = uint256(_position.marginAmount) * 800 / 1000;
        }
    }

    function modify(uint256 positionId, int256 changeAmount) external payable {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        HookStatus memory _status = hook.getStatus(_position.poolId);
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        uint256 amount = changeAmount < 0 ? uint256(-changeAmount) : uint256(changeAmount);
        if (changeAmount > 0) {
            bool b = marginToken.transfer(msg.sender, address(this), amount);
            _position.marginAmount += uint128(amount);
            require(b, "TRANSFER_ERR");
        } else {
            require(amount <= _getMaxDecrease(_position), "OVER_AMOUNT");
            bool b = marginToken.transfer(address(this), msg.sender, amount);
            _position.marginAmount -= uint128(amount);
            require(b, "TRANSFER_ERR");
        }
        emit Modify(
            _position.poolId,
            msg.sender,
            positionId,
            _position.marginAmount,
            _position.marginTotal,
            _position.borrowAmount
        );
    }

    receive() external payable onlyMargin {}
}
