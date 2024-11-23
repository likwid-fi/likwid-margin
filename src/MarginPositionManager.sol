// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
// Local
import {CurrencyUtils} from "./libraries/CurrencyUtils.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMarginHookManager} from "./interfaces/IMarginHookManager.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {MarginParams, RepayParams, LiquidateParams} from "./types/MarginParams.sol";
import {Math} from "./libraries/Math.sol";

import {console} from "forge-std/console.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned {
    using CurrencyUtils for Currency;
    using CurrencyLibrary for Currency;

    error PairNotExists();
    error InsufficientBorrowReceived();

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 private _nextId = 1;

    IMarginHookManager public hook;

    mapping(uint256 => MarginPosition) private _positions;
    mapping(address => uint256) private _hookPositions;
    mapping(address => mapping(address => mapping(address => uint256))) private _borrowPositions;

    constructor(address initialOwner) ERC721("LIKWIDMarginPositionManager", "LMPM") Owned(initialOwner) {}

    function _burnPosition(uint256 tokenId) internal {
        // _burn(tokenId);
        delete _positions[tokenId];
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "EXPIRED");
        _;
    }

    function setHook(address _hook) external onlyOwner {
        hook = IMarginHookManager(_hook);
    }

    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
        if (_position.rateCumulativeLast > 0) {
            uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.marginToken, _position.borrowToken);
            _position.borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
        }
    }

    function getPositionId(address marginToken, address borrowToken) external view returns (uint256 _positionId) {
        _positionId = _borrowPositions[marginToken][borrowToken][msg.sender];
    }

    function margin(MarginParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        bool success = Currency.wrap(params.marginToken).transfer(msg.sender, address(this), params.marginAmount);
        require(success, "MARGIN_SELL_ERR");
        uint256 positionId = _borrowPositions[params.marginToken][params.borrowToken][msg.sender];
        params = hook.margin(params);
        uint256 rateLast = hook.getBorrowRateCumulativeLast(params.marginToken, params.borrowToken);
        console.log("margin.rateLast:%s", rateLast);
        if (params.borrowAmount < params.borrowMinAmount) revert InsufficientBorrowReceived();
        if (positionId == 0) {
            _mint(msg.sender, (positionId = _nextId++));
            _positions[positionId] = MarginPosition({
                marginToken: params.marginToken,
                marginAmount: params.marginAmount,
                marginTotal: params.marginTotal,
                borrowToken: params.borrowToken,
                borrowAmount: params.borrowAmount,
                rateCumulativeLast: rateLast
            });
            _borrowPositions[params.marginToken][params.borrowToken][msg.sender] = positionId;
        } else {
            MarginPosition storage _position = _positions[positionId];
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
        if (_position.borrowToken == address(0)) {
            require(msg.value >= repayAmount, "NATIVE_AMOUNT_ERR");
        } else {
            bool r = IERC20Minimal(_position.borrowToken).allowance(msg.sender, address(hook)) >= repayAmount;
            require(r, "ALLOWANCE_AMOUNT_ERR");
        }
        uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.marginToken, _position.borrowToken);
        uint256 borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
        RepayParams memory params = RepayParams({
            marginToken: _position.marginToken,
            borrowToken: _position.borrowToken,
            payer: msg.sender,
            borrowAmount: _position.borrowAmount,
            repayAmount: repayAmount,
            deadline: deadline
        });
        hook.repay{value: msg.value}(params);
        // update position
        uint256 releaseTotal = repayAmount * _position.marginTotal / borrowAmount;
        _position.marginTotal -= releaseTotal;
        _position.borrowAmount = borrowAmount - repayAmount;
        Currency.wrap(_position.marginToken).transfer(address(this), msg.sender, releaseTotal);
        if (_position.borrowAmount == 0) {
            Currency.wrap(_position.marginToken).transfer(address(this), msg.sender, _position.marginAmount);
            _burnPosition(positionId);
        }
    }

    function checkLiquidate(uint256 positionId) public view returns (bool liquidated, uint256 releaseAmount) {
        MarginPosition memory _position = _positions[positionId];
        uint256 rateLast = hook.getBorrowRateCumulativeLast(_position.marginToken, _position.borrowToken);
        uint256 borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
        uint256 amountIn = hook.getAmountIn(_position.marginToken, _position.borrowToken, borrowAmount);
        (, uint24 _liquidationLTV) = hook.ltvParameters(_position.marginToken, _position.borrowToken);
        liquidated = amountIn > (_position.marginAmount + _position.marginTotal) * _liquidationLTV / ONE_MILLION;
        releaseAmount = Math.min(amountIn, _position.marginAmount + _position.marginTotal);
    }

    function liquidate(uint256 positionId) external returns (uint256 profit) {
        (bool liquidated, uint256 releaseAmount) = checkLiquidate(positionId);
        if (!liquidated) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];

        uint256 liquidateValue = 0;
        if (_position.marginToken == address(0)) {
            liquidateValue = releaseAmount;
        } else {
            bool success = Currency.wrap(_position.marginToken).transfer(address(this), address(hook), releaseAmount);
            require(success, "TRANSFER_ERR");
        }
        LiquidateParams memory params = LiquidateParams({
            marginToken: _position.marginToken,
            borrowToken: _position.borrowToken,
            releaseAmount: releaseAmount
        });
        hook.liquidate{value: liquidateValue}(params);
        profit = _position.marginAmount + _position.marginTotal - releaseAmount;
        if (profit > 0) {
            Currency.wrap(_position.marginToken).transfer(address(this), msg.sender, profit);
        }
        _burnPosition(positionId);
    }

    function withdrawFee(address token, address to, uint256 amount) external onlyOwner returns (bool success) {
        success = Currency.wrap(token).transfer(to, address(this), amount);
    }

    receive() external payable {}
}
