// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
// Local
import {CurrencySettleTake} from "./libraries/CurrencySettleTake.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMarginHookFactory} from "./interfaces/IMarginHookFactory.sol";
import {IMarginHook} from "./interfaces/IMarginHook.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {BorrowParams} from "./types/BorrowParams.sol";
import {Math} from "./libraries/Math.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned {
    using CurrencySettleTake for Currency;
    using CurrencyLibrary for Currency;

    error PairNotExists();
    error InsufficientBorrowReceived();

    uint256 public constant ONE_MILLION = 10 ** 6;
    uint256 private _nextId = 1;

    IMarginHookFactory public factory;

    mapping(uint256 => MarginPosition) private _positions;
    mapping(address => uint256) private _hookPositions;
    mapping(address => mapping(address => mapping(address => uint256))) private _borrowPositions;

    constructor(address initialOwner) ERC721("LIKWIDMarginPositionManager", "LMPM") Owned(initialOwner) {}

    function _burnPosition(uint256 tokenId) internal {
        _burn(tokenId);
        delete _positions[tokenId];
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "MarginPositionManager: EXPIRED");
        _;
    }

    function setFactory(address _factory) external onlyOwner {
        factory = IMarginHookFactory(_factory);
    }

    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
    }

    function getPositionId(address hook, address borrowToken) external view returns (uint256 _positionId) {
        _positionId = _borrowPositions[hook][borrowToken][msg.sender];
    }

    function borrow(BorrowParams memory params) external payable ensure(params.deadline) returns (uint256, uint256) {
        address hook = factory.getHookPair(params.borrowToken, params.marginToken);
        if (hook == address(0)) revert PairNotExists();
        bool success = Currency.wrap(params.marginToken).transfer(msg.sender, address(this), params.marginSell);
        require(success, "MARGIN_SELL_ERR");
        uint256 rateLast;
        (rateLast, params) = IMarginHook(hook).borrow(params);
        if (params.borrowAmount < params.borrowMinAmount) revert InsufficientBorrowReceived();
        (, uint24 _liquidationLTV) = IMarginHook(hook).ltvParameters();
        uint256 positionId = _borrowPositions[hook][params.borrowToken][msg.sender];
        if (positionId == 0) {
            _mint(msg.sender, (positionId = _nextId++));
            _positions[positionId] = MarginPosition({
                nonce: 0,
                operator: address(this),
                marginToken: params.marginToken,
                marginSell: params.marginSell,
                marginTotal: params.marginTotal,
                borrowToken: params.borrowToken,
                borrowAmount: params.borrowAmount,
                liquidationAmount: params.marginSell * _liquidationLTV / ONE_MILLION + params.marginTotal,
                rateCumulativeLast: rateLast
            });
            _borrowPositions[hook][params.borrowToken][msg.sender] = positionId;
        } else {
            MarginPosition storage _position = _positions[positionId];
            _position.nonce++;
            _position.marginSell += params.marginSell;
            _position.marginTotal += params.marginTotal;
            _position.borrowAmount = _position.borrowAmount * rateLast / _position.rateCumulativeLast;
            _position.borrowAmount += params.borrowAmount;
            _position.liquidationAmount += params.marginSell * _liquidationLTV / ONE_MILLION + params.marginTotal;
            _position.rateCumulativeLast = rateLast;
        }

        if (!isApprovedForAll(msg.sender, address(this))) {
            _setApprovalForAll(msg.sender, address(this), true);
        }
        return (positionId, params.borrowAmount);
    }

    function repay(uint256 positionId, uint256 repayAmount) external payable {
        require(ownerOf(positionId) == msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        address hook = factory.getHookPair(_position.borrowToken, _position.marginToken);
        if (hook == address(0)) revert PairNotExists();
        if (_position.borrowToken == address(0)) {
            require(msg.value >= repayAmount, "NATIVE_AMOUNT_ERR");
        } else {
            bool allowanceFlag = IERC20Minimal(_position.borrowToken).allowance(msg.sender, hook) >= repayAmount;
            require(allowanceFlag, "ALLOWANCE_AMOUNT_ERR");
        }
        IMarginHook(hook).repay{value: msg.value}(
            msg.sender, _position.borrowToken, _position.borrowAmount, repayAmount
        );
        // update position
        uint256 releaseTotal = repayAmount * _position.marginTotal / _position.borrowAmount;
        _position.nonce++;
        _position.marginTotal -= releaseTotal;
        _position.borrowAmount -= repayAmount;
        _position.liquidationAmount -= releaseTotal;
        Currency.wrap(_position.marginToken).transfer(address(this), msg.sender, releaseTotal);
        if (_position.borrowAmount == 0) {
            Currency.wrap(_position.marginToken).transfer(address(this), msg.sender, _position.marginSell);
            _burnPosition(positionId);
        }
    }

    function checkLiquidate(uint256 positionId) public view returns (bool liquided, uint256 releaseAmount) {
        MarginPosition memory _position = _positions[positionId];
        address hook = factory.getHookPair(_position.borrowToken, _position.marginToken);
        if (hook == address(0)) revert PairNotExists();
        uint256 amountIn = IMarginHook(hook).getAmountIn(_position.marginToken, _position.borrowAmount);
        liquided = amountIn > _position.liquidationAmount;
        releaseAmount = Math.min(amountIn, _position.marginSell + _position.marginTotal);
    }

    function liquidate(uint256 positionId) external returns (uint256 profit) {
        (bool liquided, uint256 releaseAmount) = checkLiquidate(positionId);
        if (!liquided) {
            return profit;
        }
        MarginPosition memory _position = _positions[positionId];
        address hook = factory.getHookPair(_position.borrowToken, _position.marginToken);
        if (hook == address(0)) revert PairNotExists();
        uint256 liquidateValue = 0;
        if (_position.marginToken == address(0)) {
            liquidateValue = releaseAmount;
        } else {
            bool success = Currency.wrap(_position.marginToken).transfer(address(this), hook, releaseAmount);
            require(success, "TRANSFER_ERR");
        }
        IMarginHook(hook).liquidate{value: liquidateValue}(
            _position.marginToken, releaseAmount, _position.borrowAmount, _position.borrowAmount
        );
        profit = _position.marginSell + _position.marginTotal - releaseAmount;
        if (profit > 0) {
            Currency.wrap(_position.marginToken).transfer(address(this), msg.sender, profit);
        }
        _burnPosition(positionId);
    }

    function withdrawFee(address to, uint256 amount) external onlyOwner returns (bool) {
        (bool success,) = to.call{value: amount}("");
        return success;
    }

    function withdrawToken(address to, address tokenAddr) external onlyOwner {
        uint256 balance = IERC20Minimal(tokenAddr).balanceOf(address(this));
        if (balance > 0) {
            IERC20Minimal(tokenAddr).transfer(to, balance);
        }
    }

    receive() external payable {}
}
