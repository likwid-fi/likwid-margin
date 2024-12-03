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
import {MarginPosition} from "./types/MarginPosition.sol";
import {HookStatus} from "./types/HookStatus.sol";
import {MarginParams, RepayParams, LiquidateParams} from "./types/MarginParams.sol";
import {Math} from "./libraries/Math.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned {
    using CurrencyUtils for Currency;
    using CurrencyLibrary for Currency;

    error PairNotExists();
    error InsufficientBorrowReceived();

    event Mint(address indexed sender, PoolId poolId, uint256 positionId);
    event Burn(address indexed sender, PoolId poolId, uint256 positionId);

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 private _nextId = 1;

    IMarginHookManager private hook;

    mapping(uint256 => MarginPosition) private _positions;
    mapping(address => uint256) private _hookPositions;
    mapping(PoolId => mapping(bool => mapping(address => uint256))) private _borrowPositions;

    constructor(address initialOwner) ERC721("LIKWIDMarginPositionManager", "LMPM") Owned(initialOwner) {}

    function _burnPosition(uint256 positionId) internal {
        // _burn(positionId);
        MarginPosition memory _position = _positions[positionId];
        delete _borrowPositions[_position.poolId][_position.marginForOne][ownerOf(positionId)];
        delete _positions[positionId];
        emit Burn(msg.sender, _position.poolId, positionId);
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    function transferNative(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "Transfer failed.");
    }

    function setHook(address _hook) external onlyOwner {
        hook = IMarginHookManager(_hook);
    }

    function getHook() external view returns (address _hook) {
        _hook = address(hook);
    }

    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.poolId, _position.marginForOne);
            _position.borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
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

    function margin(MarginParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        HookStatus memory _status = hook.getStatus(params.poolId);
        Currency marginToken = params.marginForOne ? _status.key.currency1 : _status.key.currency0;
        require(checkAmount(marginToken, msg.sender, address(this), params.marginAmount), "INSUFFICIENT_AMOUNT");
        bool success = marginToken.transfer(msg.sender, address(this), params.marginAmount);
        require(success, "MARGIN_SELL_ERR");
        uint256 positionId = _borrowPositions[params.poolId][params.marginForOne][params.recipient];
        params = hook.margin(params);
        uint256 rateLast = hook.getBorrowRateCumulativeLast(params.poolId, params.marginForOne);
        if (params.borrowAmount < params.borrowMinAmount) revert InsufficientBorrowReceived();
        if (positionId == 0) {
            _mint(params.recipient, (positionId = _nextId++));
            emit Mint(msg.sender, params.poolId, positionId);
            _positions[positionId] = MarginPosition({
                poolId: params.poolId,
                marginForOne: params.marginForOne,
                marginAmount: params.marginAmount,
                marginTotal: params.marginTotal,
                borrowAmount: params.borrowAmount,
                rateCumulativeLast: rateLast
            });
            _borrowPositions[params.poolId][params.marginForOne][params.recipient] = positionId;
        } else {
            MarginPosition storage _position = _positions[positionId];
            (bool liquidated,) = checkLiquidate(_position);
            require(!liquidated, "liquidated");
            uint256 borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
            _position.marginAmount += params.marginAmount;
            _position.marginTotal += params.marginTotal;
            _position.borrowAmount = borrowAmount + params.borrowAmount;
            _position.rateCumulativeLast = rateLast;
        }

        return (positionId, params.borrowAmount);
    }

    function repay(uint256 positionId, uint256 repayAmount, uint256 deadline) external payable ensure(deadline) {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        (bool liquidated,) = checkLiquidate(_position);
        require(!liquidated, "liquidated");
        HookStatus memory _status = hook.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        require(checkAmount(borrowToken, msg.sender, address(hook), repayAmount), "INSUFFICIENT_AMOUNT");
        uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.poolId, _position.marginForOne);
        uint256 borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
        if (repayAmount > borrowAmount) {
            repayAmount = borrowAmount;
        }
        RepayParams memory params = RepayParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            borrowAmount: borrowAmount,
            repayAmount: repayAmount,
            releaseAmount: 0,
            deadline: deadline
        });
        uint256 sendValue = Math.min(repayAmount, msg.value);
        hook.repay{value: sendValue}(params);
        // update position
        uint256 releaseMargin = repayAmount * _position.marginAmount / borrowAmount;
        uint256 releaseTotal = repayAmount * _position.marginTotal / borrowAmount;
        _position.marginAmount -= releaseMargin;
        _position.marginTotal -= releaseTotal;
        _position.borrowAmount = borrowAmount - repayAmount;
        if (_position.borrowAmount == 0) {
            marginToken.transfer(address(this), msg.sender, releaseTotal + _position.marginAmount + releaseMargin);
            _burnPosition(positionId);
        } else {
            marginToken.transfer(address(this), msg.sender, releaseTotal + releaseMargin);
        }
        if (msg.value > repayAmount) {
            transferNative(msg.sender, msg.value - repayAmount);
        }
    }

    function close(uint256 positionId, uint256 releaseAmount, uint256 deadline) external payable ensure(deadline) {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        (bool liquidated,) = checkLiquidate(_position);
        require(!liquidated, "liquidated");
        HookStatus memory _status = hook.getStatus(_position.poolId);
        Currency marginToken = _position.marginForOne ? _status.key.currency1 : _status.key.currency0;
        require(checkAmount(marginToken, msg.sender, address(hook), releaseAmount), "INSUFFICIENT_AMOUNT");
        uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.poolId, _position.marginForOne);
        uint256 borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
        uint256 repayAmount = hook.getAmountOut(_position.poolId, !_position.marginForOne, releaseAmount);
        if (repayAmount > borrowAmount) {
            repayAmount = borrowAmount;
        }
        RepayParams memory params = RepayParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            payer: msg.sender,
            borrowAmount: borrowAmount,
            repayAmount: repayAmount,
            releaseAmount: releaseAmount,
            deadline: deadline
        });
        uint256 sendValue = Math.min(releaseAmount, msg.value);
        hook.repay{value: sendValue}(params);
        // update position
        uint256 releaseMargin = repayAmount * _position.marginAmount / borrowAmount;
        uint256 releaseTotal = repayAmount * _position.marginTotal / borrowAmount;
        _position.marginAmount -= releaseMargin;
        _position.marginTotal -= releaseTotal;
        _position.borrowAmount = borrowAmount - repayAmount;
        if (_position.borrowAmount == 0) {
            marginToken.transfer(address(this), msg.sender, releaseTotal + _position.marginAmount + releaseMargin);
            _burnPosition(positionId);
        } else {
            marginToken.transfer(address(this), msg.sender, releaseTotal + releaseMargin);
        }
    }

    function checkLiquidate(MarginPosition memory _position)
        private
        view
        returns (bool liquidated, uint256 amountNeed)
    {
        uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.poolId, _position.marginForOne);
        uint256 borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
        amountNeed = hook.getAmountIn(_position.poolId, !_position.marginForOne, borrowAmount);
        (, uint24 _liquidationLTV) = hook.ltvParameters(_position.poolId);
        liquidated = amountNeed > _position.marginAmount * _liquidationLTV / ONE_MILLION + _position.marginTotal;
    }

    function checkLiquidate(uint256 positionId) public view returns (bool liquidated, uint256 releaseAmount) {
        MarginPosition memory _position = _positions[positionId];
        uint256 amountNeed;
        (liquidated, amountNeed) = checkLiquidate(_position);
        releaseAmount = Math.min(amountNeed, _position.marginAmount + _position.marginTotal);
    }

    function liquidateBurn(uint256 positionId) external returns (uint256 profit) {
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
        LiquidateParams memory params = LiquidateParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            releaseAmount: releaseAmount,
            repayAmount: 1,
            borrowAmount: 1
        });
        hook.liquidate{value: liquidateValue}(params);
        profit = _position.marginAmount + _position.marginTotal - releaseAmount;
        if (profit > 0) {
            marginToken.transfer(address(this), msg.sender, profit);
        }
        _burnPosition(positionId);
    }

    function liquidate(uint256 positionId) external returns (uint256 profit) {
        (bool liquidated,) = checkLiquidate(positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];
        HookStatus memory _status = hook.getStatus(_position.poolId);
        (Currency borrowToken, Currency marginToken) = _position.marginForOne
            ? (_status.key.currency0, _status.key.currency1)
            : (_status.key.currency1, _status.key.currency0);
        uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.poolId, _position.marginForOne);
        uint256 borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
        require(checkAmount(borrowToken, msg.sender, address(hook), borrowAmount), "INSUFFICIENT_AMOUNT");
        uint256 liquidateValue = 0;
        if (borrowToken == CurrencyLibrary.ADDRESS_ZERO) {
            liquidateValue = borrowAmount;
        }
        LiquidateParams memory params = LiquidateParams({
            poolId: _position.poolId,
            marginForOne: _position.marginForOne,
            repayAmount: borrowAmount,
            borrowAmount: borrowAmount,
            releaseAmount: 0
        });
        hook.liquidate{value: liquidateValue}(params);
        profit = _position.marginAmount + _position.marginTotal;
        marginToken.transfer(address(this), msg.sender, profit);
        _burnPosition(positionId);
    }

    function withdrawFee(address token, address to, uint256 amount) external onlyOwner returns (bool success) {
        success = Currency.wrap(token).transfer(to, address(this), amount);
    }

    receive() external payable {}
}
