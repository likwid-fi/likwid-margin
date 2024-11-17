// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMarginHookFactory} from "./interfaces/IMarginHookFactory.sol";
import {IMarginHook} from "./interfaces/IMarginHook.sol";
import {MarginPosition} from "./types/MarginPosition.sol";
import {BorrowParams} from "./types/BorrowParams.sol";

contract MarginPositionManager is IMarginPositionManager, ERC721, Owned {
    error NotHook();

    uint256 private _nextId = 1;

    mapping(uint256 => MarginPosition) private _positions;
    mapping(address => uint256) private _hookPositions;
    mapping(address => mapping(address => mapping(address => uint256))) private _borrowPositions;

    constructor(address initialOwner) ERC721("LIKWIDMarginPositionManager", "LMPM") Owned(initialOwner) {}

    function getPosition(uint256 positionId) external view returns (MarginPosition memory _position) {
        _position = _positions[positionId];
    }

    function borrowToken(IMarginHookFactory factory, BorrowParams memory params) external payable {
        address hook = factory.getHookPair(params.borrowToken, params.marginToken);
        require(hook != address(0), "HOOK_NOT_EXISTS");
        address zeroToken = params.borrowToken < params.marginToken ? params.borrowToken : params.marginToken;
        if (zeroToken == address(0)) {
            require(msg.value >= params.marginSell, "NATIVE_AMOUNT_ERR");
        }
        params = IMarginHook(hook).borrowToken{value: msg.value}(params);
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
                liquidationAmount: params.marginSell * _liquidationLTV / 10 ** 4 + params.marginTotal
            });
        } else {
            MarginPosition storage _position = _positions[positionId];
            _position.nonce++;
            _position.marginSell += params.marginSell;
            _position.marginTotal += params.marginTotal;
            _position.borrowAmount += params.borrowAmount;
            _position.liquidationAmount += params.marginSell * _liquidationLTV / 10 ** 4 + params.marginTotal;
        }

        if (!isApprovedForAll(msg.sender, address(this))) {
            _setApprovalForAll(msg.sender, address(this), true);
        }
    }

    function returnToken(IMarginHookFactory factory, uint256 positionId, uint256 returnAmount) external payable {
        require(ownerOf(positionId) != msg.sender, "AUTH_ERROR");
        MarginPosition storage _position = _positions[positionId];
        address hook = factory.getHookPair(_position.borrowToken, _position.marginToken);
        require(hook != address(0), "HOOK_NOT_EXISTS");
        address zeroToken =
            _position.borrowToken < _position.marginToken ? _position.borrowToken : _position.marginToken;
        if (zeroToken == address(0)) {
            require(msg.value >= returnAmount, "NATIVE_AMOUNT_ERR");
        }
        (uint256 releaseSell, uint256 releaseTotal) =
            IMarginHook(hook).returnToken{value: msg.value}(msg.sender, positionId, returnAmount);
        // update position
        _position.marginSell -= releaseSell;
        _position.marginTotal -= releaseTotal;
        _position.borrowAmount -= returnAmount;
        _position.nonce += 1;
        if (_position.borrowAmount == 0) {
            _burn(positionId);
        }
    }
}
