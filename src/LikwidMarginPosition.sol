// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";
// Local
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {PoolId} from "./types/PoolId.sol";
import {Math} from "./libraries/Math.sol";
import {CurrencyPoolLibrary} from "./libraries/CurrencyPoolLibrary.sol";
import {BasePositionManager} from "./base/BasePositionManager.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IProtocolFees} from "./interfaces/IProtocolFees.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {FeeLibrary} from "./libraries/FeeLibrary.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {MarginPosition} from "./libraries/MarginPosition.sol";
import {StateLibrary} from "./libraries/StateLibrary.sol";
import {PositionLibrary} from "./libraries/PositionLibrary.sol";
import {BalanceDelta} from "./types/BalanceDelta.sol";
import {Reserves} from "./types/Reserves.sol";
import {MarginLevels, MarginLevelsLibrary} from "./types/MarginLevels.sol";

contract LikwidMarginPosition is IMarginPositionManager, BasePositionManager {
    using SafeCast for *;
    using CurrencyLibrary for Currency;
    using CurrencyPoolLibrary for Currency;
    using PerLibrary for uint256;
    using FeeLibrary for uint24;
    using CustomRevert for bytes4;
    using PositionLibrary for address;
    using MarginLevelsLibrary for MarginLevels;

    error PairNotExists();
    error PositionLiquidated();
    error PositionNotLiquidated();
    error MarginTransferFailed(uint256 amount);
    error InvalidLevel();

    event Mint(PoolId indexed poolId, address indexed sender, address indexed to, uint256 positionId);
    event Burn(PoolId indexed poolId, address indexed sender, uint256 positionId, uint8 burnType);
    event Margin(
        PoolId indexed poolId,
        address indexed owner,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount,
        bool marginForOne
    );
    event RepayClose(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 releaseMarginAmount,
        uint256 releaseMarginTotal,
        uint256 repayAmount,
        uint256 repayRawAmount,
        int256 pnlAmount
    );
    event Modify(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount,
        int256 changeAmount
    );
    event Liquidate(
        PoolId indexed poolId,
        address indexed sender,
        uint256 positionId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 borrowAmount,
        uint256 oracleReserves,
        uint256 statusReserves
    );

    event CheckerChanged(address indexed oldChecker, address indexed newChecker);
    event LiquidationRatioChanged(uint24 oldRatio, uint24 newRatio);
    event CallerProfitChanged(uint24 oldProfit, uint24 newProfit);
    event ProtocolProfitChanged(uint24 oldProfit, uint24 newProfit);

    enum BurnType {
        REPAY,
        CLOSE,
        LIQUIDATE_BURN,
        LIQUIDATE_CALL
    }

    mapping(uint256 tokenId => PositionInfo positionInfo) public positionInfos;
    MarginLevels public marginLevels;

    constructor(address initialOwner, IVault _vault)
        BasePositionManager("LIKWIDMarginPositionManager", "LMPM", initialOwner, _vault)
    {
        MarginLevels _marginLevels;
        _marginLevels = _marginLevels.setMinMarginLevel(1170000);
        _marginLevels = _marginLevels.setMinBorrowLevel(1400000);
        _marginLevels = _marginLevels.setLiquidateLevel(1100000);
        _marginLevels = _marginLevels.setLiquidationRatio(950000);
        _marginLevels = _marginLevels.setCallerProfit(10000);
        _marginLevels = _marginLevels.setProtocolProfit(5000);
        marginLevels = _marginLevels;
    }

    enum Actions {
        MARGIN,
        REPAY,
        CLOSE,
        MODIFY,
        LIQUIDATE_BURN,
        LIQUIDATE_CALL
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (Actions action, bytes memory params) = abi.decode(data, (Actions, bytes));

        if (
            action == Actions.MARGIN || action == Actions.REPAY || action == Actions.MODIFY
                || action == Actions.LIQUIDATE_CALL
        ) {
            return handleMargin(params);
        }
        if (action == Actions.LIQUIDATE_BURN) {
            return handleLiquidateBurn(params);
        } else {
            InvalidCallback.selector.revertWith();
        }
    }

    struct PositionInfo {
        bool marginForOne;
        bool isBorrow;
    }

    function getPositionState(uint256 tokenId) external view returns (MarginPosition.State memory position) {
        bytes32 salt = bytes32(tokenId);
        PoolId poolId = poolIds[tokenId];
        PositionInfo memory info = positionInfos[tokenId];
        (
            uint256 borrow0CumulativeLast,
            uint256 borrow1CumulativeLast,
            uint256 deposit0CumulativeLast,
            uint256 deposit1CumulativeLast
        ) = StateLibrary.getBorrowDepositCumulative(vault, poolId);
        uint256 depositCumulativeLast = info.marginForOne ? deposit1CumulativeLast : deposit0CumulativeLast;
        uint256 borrowCumulativeLast = info.marginForOne ? borrow0CumulativeLast : borrow1CumulativeLast;
        position = StateLibrary.getMarginPositionState(vault, poolId, address(this), info.isBorrow, salt);
        position.marginAmount =
            Math.mulDiv(position.marginAmount, depositCumulativeLast, position.depositCumulativeLast).toUint128();
        position.marginTotal =
            Math.mulDiv(position.marginTotal, depositCumulativeLast, position.depositCumulativeLast).toUint128();
        position.debtAmount =
            Math.mulDiv(position.debtAmount, borrowCumulativeLast, position.borrowCumulativeLast).toUint128();

        position.depositCumulativeLast = depositCumulativeLast;
        position.borrowCumulativeLast = borrowCumulativeLast;
    }

    function checkLiquidate(uint256 tokenId)
        external
        view
        returns (bool liquidated, uint256 assetsAmount, uint256 debtAmount)
    {
        PoolId poolId = poolIds[tokenId];
        PositionInfo memory info = positionInfos[tokenId];
        (liquidated, assetsAmount, debtAmount) = _checkLiquidate(tokenId, poolId, info);
    }

    function _checkLiquidate(uint256 tokenId, PoolId poolId, PositionInfo memory info)
        internal
        view
        returns (bool liquidated, uint256 assetsAmount, uint256 debtAmount)
    {
        bytes32 salt = bytes32(tokenId);
        (
            uint256 borrow0CumulativeLast,
            uint256 borrow1CumulativeLast,
            uint256 deposit0CumulativeLast,
            uint256 deposit1CumulativeLast
        ) = StateLibrary.getBorrowDepositCumulative(vault, poolId);
        uint256 depositCumulativeLast = info.marginForOne ? deposit1CumulativeLast : deposit0CumulativeLast;
        uint256 borrowCumulativeLast = info.marginForOne ? borrow0CumulativeLast : borrow1CumulativeLast;
        MarginPosition.State memory position =
            StateLibrary.getMarginPositionState(vault, poolId, address(this), info.isBorrow, salt);
        Reserves truncatedReserves = StateLibrary.getTruncatedReserves(vault, poolId);
        uint256 level =
            MarginPosition.marginLevel(position, truncatedReserves, borrowCumulativeLast, depositCumulativeLast);
        liquidated = level < marginLevels.liquidateLevel();
        if (liquidated) {
            position.marginAmount =
                Math.mulDiv(position.marginAmount, depositCumulativeLast, position.depositCumulativeLast).toUint128();
            position.marginTotal =
                Math.mulDiv(position.marginTotal, depositCumulativeLast, position.depositCumulativeLast).toUint128();
            assetsAmount = position.marginAmount + position.marginTotal;
            debtAmount = Math.mulDiv(position.debtAmount, borrowCumulativeLast, position.borrowCumulativeLast);
        }
    }

    function addMargin(PoolKey memory key, IMarginPositionManager.CreateParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint256 borrowAmount)
    {
        tokenId = _mintPosition(key, params.recipient);
        PositionInfo storage info = positionInfos[tokenId];
        info.marginForOne = params.marginForOne;
        info.isBorrow = params.leverage > 0;
        borrowAmount = margin(
            IMarginPositionManager.MarginParams({
                tokenId: tokenId,
                leverage: params.leverage,
                marginAmount: params.marginAmount,
                borrowAmount: params.borrowAmount,
                borrowAmountMax: params.borrowAmountMax,
                deadline: params.deadline
            })
        );
    }

    /// @inheritdoc IMarginPositionManager
    function margin(IMarginPositionManager.MarginParams memory params)
        public
        payable
        nonReentrant
        ensure(params.deadline)
        returns (uint256 borrowAmount)
    {
        _requireAuth(msg.sender, params.tokenId);
        PositionInfo memory info = positionInfos[params.tokenId];
        PoolId poolId = poolIds[params.tokenId];
        PoolKey memory key = poolKeys[poolId];
        uint128 marginTotal = (params.marginAmount * params.leverage).toUint128();
        uint24 minLevel = info.isBorrow ? marginLevels.minBorrowLevel() : marginLevels.minMarginLevel();

        IVault.MarginParams memory marginParams = IVault.MarginParams({
            marginForOne: info.marginForOne,
            amount: -params.marginAmount.toInt128(),
            marginTotal: marginTotal,
            borrowAmount: params.borrowAmount.toUint128(),
            changeAmount: 0,
            minMarginLevel: minLevel,
            salt: bytes32(params.tokenId)
        });

        bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        bytes memory data = abi.encode(Actions.MARGIN, callbackData);

        bytes memory result = vault.unlock(data);
        (borrowAmount) = abi.decode(result, (uint256));
        if (info.isBorrow && borrowAmount > params.borrowAmountMax) {
            InsufficientBorrowReceived.selector.revertWith();
        }
    }

    /// @inheritdoc IMarginPositionManager
    function repay(uint256 tokenId, uint256 repayAmount, uint256 deadline)
        external
        payable
        nonReentrant
        ensure(deadline)
    {
        _requireAuth(msg.sender, tokenId);
        PositionInfo memory info = positionInfos[tokenId];
        PoolId poolId = poolIds[tokenId];
        PoolKey memory key = poolKeys[poolId];
        uint24 minLevel = info.isBorrow ? marginLevels.minBorrowLevel() : marginLevels.minMarginLevel();

        IVault.MarginParams memory marginParams = IVault.MarginParams({
            marginForOne: info.marginForOne,
            amount: repayAmount.toInt128(),
            marginTotal: 0,
            borrowAmount: 0,
            changeAmount: 0,
            minMarginLevel: minLevel,
            salt: bytes32(tokenId)
        });

        bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        bytes memory data = abi.encode(Actions.REPAY, callbackData);

        vault.unlock(data);
    }

    /// @inheritdoc IMarginPositionManager
    function close(uint256 tokenId, uint24 closeMillionth, uint256 profitAmountMin, uint256 deadline)
        external
        nonReentrant
        ensure(deadline)
    {
        _requireAuth(msg.sender, tokenId);
        PositionInfo memory info = positionInfos[tokenId];
        PoolId poolId = poolIds[tokenId];
        PoolKey memory key = poolKeys[poolId];
        bytes32 salt = bytes32(tokenId);
        bytes32 positionKey = address(this).calculatePositionKey(info.isBorrow, salt);
        IVault.CloseParams memory marginParams = IVault.CloseParams({
            positionKey: positionKey,
            rewardAmount: 0,
            closeMillionth: closeMillionth,
            salt: bytes32(tokenId)
        });

        bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        bytes memory data = abi.encode(Actions.CLOSE, callbackData);

        bytes memory result = vault.unlock(data);
        (uint256 profitAmount) = abi.decode(result, (uint256));
        if (profitAmount < profitAmountMin) {
            InsufficientCloseReceived.selector.revertWith();
        }
    }

    function liquidateBurn(uint256 tokenId) external nonReentrant returns (uint256 profit) {
        PositionInfo memory info = positionInfos[tokenId];
        PoolId poolId = poolIds[tokenId];
        (bool liquidated, uint256 assetsAmount,) = _checkLiquidate(tokenId, poolId, info);
        if (!liquidated) {
            PositionNotLiquidated.selector.revertWith();
        }
        uint256 callerProfitAmount = assetsAmount.mulDivMillion(marginLevels.callerProfit());
        uint256 protocolProfitAmount = assetsAmount.mulDivMillion(marginLevels.protocolProfit());
        PoolKey memory key = poolKeys[poolId];
        bytes32 salt = bytes32(tokenId);
        bytes32 positionKey = address(this).calculatePositionKey(info.isBorrow, salt);
        IVault.CloseParams memory marginParams = IVault.CloseParams({
            positionKey: positionKey,
            rewardAmount: callerProfitAmount + protocolProfitAmount,
            closeMillionth: uint24(PerLibrary.ONE_MILLION),
            salt: bytes32(tokenId)
        });

        bytes memory callbackData =
            abi.encode(msg.sender, key, marginParams, info.marginForOne, callerProfitAmount, protocolProfitAmount);
        bytes memory data = abi.encode(Actions.LIQUIDATE_BURN, callbackData);

        bytes memory result = vault.unlock(data);
        profit = abi.decode(result, (uint256));
    }

    function liquidateCall(uint256 tokenId)
        external
        payable
        nonReentrant
        returns (uint256 profit, uint256 repayAmount)
    {
        PositionInfo memory info = positionInfos[tokenId];
        PoolId poolId = poolIds[tokenId];
        (bool liquidated, uint256 assetsAmount, uint256 debtAmount) = _checkLiquidate(tokenId, poolId, info);
        if (!liquidated) {
            PositionNotLiquidated.selector.revertWith();
        }
        Reserves pairReserves = StateLibrary.getPairReserves(vault, poolId);
        (uint128 reserve0, uint128 reserve1) = pairReserves.reserves();
        (uint256 reserveBorrow, uint256 reserveMargin) = info.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint24 _liquidationRatio = marginLevels.liquidationRatio();
        repayAmount = Math.mulDiv(reserveBorrow, assetsAmount, reserveMargin);
        repayAmount = repayAmount.mulDivMillion(_liquidationRatio);
        profit = assetsAmount;
        PoolKey memory key = poolKeys[poolId];
        IVault.MarginParams memory marginParams = IVault.MarginParams({
            marginForOne: info.marginForOne,
            amount: debtAmount.toInt128(),
            marginTotal: 0,
            borrowAmount: 0,
            changeAmount: repayAmount.toInt128(),
            minMarginLevel: 1, // no zero level
            salt: bytes32(tokenId)
        });

        bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        bytes memory data = abi.encode(Actions.LIQUIDATE_CALL, callbackData);

        vault.unlock(data);
    }

    /// @inheritdoc IMarginPositionManager
    function modify(uint256 tokenId, int128 changeAmount) external payable nonReentrant {
        _requireAuth(msg.sender, tokenId);
        PositionInfo memory info = positionInfos[tokenId];
        PoolId poolId = poolIds[tokenId];
        PoolKey memory key = poolKeys[poolId];
        uint24 minLevel = info.isBorrow ? marginLevels.minBorrowLevel() : marginLevels.minMarginLevel();

        IVault.MarginParams memory marginParams = IVault.MarginParams({
            marginForOne: info.marginForOne,
            amount: 0,
            marginTotal: 0,
            borrowAmount: 0,
            changeAmount: changeAmount,
            minMarginLevel: minLevel,
            salt: bytes32(tokenId)
        });

        bytes memory callbackData = abi.encode(msg.sender, key, marginParams);
        bytes memory data = abi.encode(Actions.MODIFY, callbackData);

        vault.unlock(data);
    }

    function handleMargin(bytes memory _data) internal returns (bytes memory) {
        (address sender, PoolKey memory key, IVault.MarginParams memory params) =
            abi.decode(_data, (address, PoolKey, IVault.MarginParams));

        (BalanceDelta delta, uint256 assetAmount,) = vault.margin(key, params);

        _processDelta(sender, key, delta, 0, 0, 0, 0);

        return abi.encode(assetAmount);
    }

    function handleClose(bytes memory _data) internal returns (bytes memory) {
        (address sender, PoolKey memory key, IVault.CloseParams memory params) =
            abi.decode(_data, (address, PoolKey, IVault.CloseParams));

        (BalanceDelta delta, uint256 profitAmount) = vault.close(key, params);

        _processDelta(sender, key, delta, 0, 0, 0, 0);

        return abi.encode(profitAmount);
    }

    function handleLiquidateBurn(bytes memory _data) internal returns (bytes memory) {
        (
            address sender,
            PoolKey memory key,
            IVault.CloseParams memory params,
            bool marginForOne,
            uint256 callerProfitAmount,
            uint256 protocolProfitAmount
        ) = abi.decode(_data, (address, PoolKey, IVault.CloseParams, bool, uint256, uint256));

        (, uint256 profitAmount) = vault.close(key, params);
        if (profitAmount > callerProfitAmount) {
            protocolProfitAmount = profitAmount - callerProfitAmount;
        } else {
            protocolProfitAmount = 0;
            callerProfitAmount = profitAmount;
        }
        Currency marginCurrency = marginForOne ? key.currency1 : key.currency0;
        if (protocolProfitAmount > 0) {
            address feeTo = IProtocolFees(address(vault)).protocolFeeController();
            if (feeTo == address(0)) {
                feeTo = owner;
            }
            marginCurrency.take(vault, feeTo, protocolProfitAmount, false);
        }
        if (callerProfitAmount > 0) {
            marginCurrency.take(vault, sender, callerProfitAmount, false);
        }

        return abi.encode(profitAmount);
    }

    function setMinMarginLevel(uint24 _minMarginLevel) external onlyOwner {
        if (_minMarginLevel < marginLevels.liquidateLevel()) {
            InvalidLevel.selector.revertWith();
        }
        uint24 old = marginLevels.minMarginLevel();
        marginLevels = marginLevels.setMinMarginLevel(_minMarginLevel);
        emit MinMarginLevelChanged(old, _minMarginLevel);
    }

    function setMinBorrowLevel(uint24 _minBorrowLevel) external onlyOwner {
        if (_minBorrowLevel < marginLevels.liquidateLevel()) {
            InvalidLevel.selector.revertWith();
        }
        uint24 old = marginLevels.minBorrowLevel();
        marginLevels = marginLevels.setMinBorrowLevel(_minBorrowLevel);
        emit MinBorrowLevelChanged(old, _minBorrowLevel);
    }

    function setLiquidateLevel(uint24 _liquidateLevel) external onlyOwner {
        if (marginLevels.minMarginLevel() < _liquidateLevel || marginLevels.minBorrowLevel() < _liquidateLevel) {
            InvalidLevel.selector.revertWith();
        }
        uint24 old = marginLevels.liquidateLevel();
        marginLevels = marginLevels.setLiquidateLevel(_liquidateLevel);
        emit LiquidateLevelChanged(old, _liquidateLevel);
    }

    function setLiquidationRatio(uint24 _liquidationRatio) external onlyOwner {
        uint24 old = marginLevels.liquidationRatio();
        marginLevels = marginLevels.setLiquidationRatio(_liquidationRatio);
        emit LiquidationRatioChanged(old, _liquidationRatio);
    }

    function setCallerProfit(uint24 _callerProfit) external onlyOwner {
        uint24 old = marginLevels.callerProfit();
        marginLevels = marginLevels.setCallerProfit(_callerProfit);
        emit CallerProfitChanged(old, _callerProfit);
    }

    function setProtocolProfit(uint24 _protocolProfit) external onlyOwner {
        uint24 old = marginLevels.protocolProfit();
        marginLevels = marginLevels.setProtocolProfit(_protocolProfit);
        emit ProtocolProfitChanged(old, _protocolProfit);
    }
}
