// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Openzeppelin
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
// Local
import {BasePositionManager} from "./base/BasePositionManager.sol";
import {IMarginPositionManager} from "./interfaces/IMarginPositionManager.sol";
import {IMarginCore} from "./interfaces/IMarginCore.sol";
import {IMarginRefinancer} from "./interfaces/IMarginRefinancer.sol";
import {IVault} from "./interfaces/IVault.sol";
import {MarginPosition} from "./libraries/MarginPosition.sol";
import {MarginActions} from "./types/MarginActions.sol";
import {BalanceDelta} from "./types/BalanceDelta.sol";
import {Currency} from "./types/Currency.sol";
import {PoolId} from "./types/PoolId.sol";
import {PoolKey} from "./types/PoolKey.sol";

/// @title Likwid margin position manager
/// @notice Thin NFT wrapper: each tokenId is a margin position held in the margin core,
/// owned by this contract with salt = bytes32(tokenId). This contract only handles
/// token ownership, currency settlement with the user, per-user event attribution, and
/// forwarding to the core. Position direction and risk parameters live on the core.
contract LikwidMarginPosition is IMarginPositionManager, BasePositionManager {
    using SafeERC20 for IERC20;

    IMarginCore public immutable marginCore;

    /// @notice Emitted when a position is created or increased (user-attributed by tokenId/owner)
    event Margin(
        PoolId indexed poolId,
        address indexed owner,
        uint256 indexed tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        bool marginForOne
    );

    event Repay(
        PoolId indexed poolId,
        address indexed owner,
        uint256 indexed tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount
    );

    event Close(
        PoolId indexed poolId,
        address indexed owner,
        uint256 indexed tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount
    );

    event Modify(
        PoolId indexed poolId,
        address indexed owner,
        uint256 indexed tokenId,
        uint256 marginAmount,
        uint256 marginTotal,
        uint256 debtAmount,
        int128 changeAmount
    );

    /// @notice Emitted when a position is handed to a refinancer and its NFT is burned
    event Refinanced(PoolId indexed poolId, address indexed owner, uint256 indexed tokenId, address refinancer);

    constructor(address initialOwner, IVault _vault, IMarginCore _marginCore)
        BasePositionManager("LIKWIDMarginPositionManager", "LMPM", initialOwner, _vault)
    {
        marginCore = _marginCore;
    }

    /// @inheritdoc IMarginPositionManager
    function getPositionState(uint256 tokenId) external view returns (MarginPosition.State memory position) {
        position = marginCore.getPositionState(poolIds[tokenId], address(this), bytes32(tokenId));
    }

    /// @inheritdoc IMarginPositionManager
    function addMargin(PoolKey memory key, IMarginPositionManager.CreateParams calldata params)
        external
        payable
        ensure(params.deadline)
        returns (uint256 tokenId, uint256 borrowAmount, uint256 swapFeeAmount)
    {
        tokenId = _mintPosition(key, params.recipient);
        (borrowAmount, swapFeeAmount) = _margin(
            msg.sender,
            params.recipient,
            params.marginForOne,
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
        external
        payable
        ensure(params.deadline)
        returns (uint256 borrowAmount, uint256 swapFeeAmount)
    {
        // Direction of an existing position is fixed on the core; read it so the core's
        // direction check passes.
        bool marginForOne =
            marginCore.positionMarginForOne(poolIds[params.tokenId], address(this), bytes32(params.tokenId));
        (borrowAmount, swapFeeAmount) = _margin(msg.sender, msg.sender, marginForOne, params);
    }

    function _margin(
        address sender,
        address tokenOwner,
        bool marginForOne,
        IMarginPositionManager.MarginParams memory params
    ) internal returns (uint256 borrowAmount, uint256 swapFeeAmount) {
        _requireAuth(tokenOwner, params.tokenId);
        bytes memory result =
            vault.unlock(abi.encode(MarginActions.MARGIN, abi.encode(sender, marginForOne, params)));
        (borrowAmount, swapFeeAmount) = abi.decode(result, (uint256, uint256));
        MarginPosition.State memory p = _readState(params.tokenId);
        emit Margin(
            poolIds[params.tokenId], tokenOwner, params.tokenId, p.marginAmount, p.marginTotal, p.debtAmount, marginForOne
        );
    }

    /// @inheritdoc IMarginPositionManager
    function repay(uint256 tokenId, uint256 repayAmount, uint256 deadline) external payable ensure(deadline) {
        _requireAuth(msg.sender, tokenId);
        vault.unlock(abi.encode(MarginActions.REPAY, abi.encode(msg.sender, tokenId, repayAmount)));
        MarginPosition.State memory p = _readState(tokenId);
        emit Repay(poolIds[tokenId], msg.sender, tokenId, p.marginAmount, p.marginTotal, p.debtAmount);
    }

    /// @inheritdoc IMarginPositionManager
    function close(uint256 tokenId, uint24 closeMillionth, uint256 closeAmountMin, uint256 deadline)
        external
        ensure(deadline)
    {
        _requireAuth(msg.sender, tokenId);
        vault.unlock(abi.encode(MarginActions.CLOSE, abi.encode(msg.sender, tokenId, closeMillionth, closeAmountMin)));
        MarginPosition.State memory p = _readState(tokenId);
        emit Close(poolIds[tokenId], msg.sender, tokenId, p.marginAmount, p.marginTotal, p.debtAmount);
    }

    /// @notice Hand the position over to a refinancer chosen by the token owner (e.g. a fixed-rate
    /// debt market that repays the pool debt). Collateral and debt move to the refinancer atomically
    /// and the NFT is burned, so no live token is left backing an emptied position.
    /// @param tokenId The id of the position
    /// @param refinancer The refinancer contract receiving the position
    /// @param data Refinancer-specific terms chosen by the caller
    /// @param deadline Deadline for the transaction
    function refinance(uint256 tokenId, IMarginRefinancer refinancer, bytes calldata data, uint256 deadline)
        external
        ensure(deadline)
    {
        _requireAuth(msg.sender, tokenId);
        PoolId poolId = poolIds[tokenId];
        PoolKey memory key = poolKeys[poolId];

        // The refinancer chooses and arms its own destination slot, so its receive hook can
        // reject any transfer it did not authorize (blocks slot pre-occupation griefing).
        bytes32 newSalt = refinancer.prepareRefinance(key, tokenId, data);

        // Burn first so no live NFT ever backs the emptied core slot, even mid-callback.
        // poolIds[tokenId] is left as-is (harmless: every mutating path checks ownerOf, which
        // reverts for a burned token).
        _burn(tokenId);

        marginCore.transferPosition(key, bytes32(tokenId), address(refinancer), newSalt);
        refinancer.onRefinance(key, newSalt, msg.sender, data);

        emit Refinanced(poolId, msg.sender, tokenId, address(refinancer));
    }

    /// @inheritdoc IMarginPositionManager
    function modify(uint256 tokenId, int128 changeAmount, uint256 deadline) external payable ensure(deadline) {
        _requireAuth(msg.sender, tokenId);
        vault.unlock(abi.encode(MarginActions.MODIFY, abi.encode(msg.sender, tokenId, changeAmount)));
        MarginPosition.State memory p = _readState(tokenId);
        emit Modify(poolIds[tokenId], msg.sender, tokenId, p.marginAmount, p.marginTotal, p.debtAmount, changeAmount);
    }

    /// @dev Reads the current (interest-accrued) position backing a tokenId.
    function _readState(uint256 tokenId) internal view returns (MarginPosition.State memory) {
        return marginCore.getPositionState(poolIds[tokenId], address(this), bytes32(tokenId));
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (MarginActions action, bytes memory params) = abi.decode(data, (MarginActions, bytes));

        if (action == MarginActions.MARGIN) {
            return _handleMargin(params);
        } else if (action == MarginActions.REPAY) {
            return _handleRepay(params);
        } else if (action == MarginActions.CLOSE) {
            return _handleClose(params);
        } else {
            return _handleModify(params);
        }
    }

    function _handleMargin(bytes memory data) internal returns (bytes memory) {
        (address sender, bool marginForOne, IMarginPositionManager.MarginParams memory params) =
            abi.decode(data, (address, bool, IMarginPositionManager.MarginParams));
        PoolKey memory key = poolKeys[poolIds[params.tokenId]];

        (uint256 borrowAmount, uint256 swapFeeAmount, BalanceDelta delta) = marginCore.margin(
            key,
            IMarginCore.MarginParams({
                salt: bytes32(params.tokenId),
                marginForOne: marginForOne,
                leverage: params.leverage,
                marginAmount: params.marginAmount,
                borrowAmount: params.borrowAmount,
                borrowAmountMax: params.borrowAmountMax,
                recipient: sender
            })
        );
        _settleNegatives(key, delta, sender);

        return abi.encode(borrowAmount, swapFeeAmount);
    }

    function _handleRepay(bytes memory data) internal returns (bytes memory) {
        (address sender, uint256 tokenId, uint256 repayAmount) = abi.decode(data, (address, uint256, uint256));
        PoolKey memory key = poolKeys[poolIds[tokenId]];

        (,, BalanceDelta delta) = marginCore.repay(key, bytes32(tokenId), repayAmount, sender);
        _settleNegatives(key, delta, sender);

        return "";
    }

    function _handleClose(bytes memory data) internal returns (bytes memory) {
        (address sender, uint256 tokenId, uint24 closeMillionth, uint256 closeAmountMin) =
            abi.decode(data, (address, uint256, uint24, uint256));
        PoolKey memory key = poolKeys[poolIds[tokenId]];

        marginCore.close(key, bytes32(tokenId), closeMillionth, closeAmountMin, sender);

        return "";
    }

    function _handleModify(bytes memory data) internal returns (bytes memory) {
        (address sender, uint256 tokenId, int128 changeAmount) = abi.decode(data, (address, uint256, int128));
        PoolKey memory key = poolKeys[poolIds[tokenId]];

        (BalanceDelta delta) = marginCore.modify(key, bytes32(tokenId), changeAmount, sender);
        _settleNegatives(key, delta, sender);

        return "";
    }

    /// @dev Pays the negative legs of a core position delta into the vault, credited to the
    /// margin core via settleFor. The positive legs were already taken by the core.
    function _settleNegatives(PoolKey memory key, BalanceDelta delta, address payer) internal {
        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            _settleFor(key.currency0, payer, uint128(-amount0));
        }
        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            _settleFor(key.currency1, payer, uint128(-amount1));
        }
        _clearNative(payer);
    }

    function _settleFor(Currency currency, address payer, uint256 amount) internal {
        if (currency.isAddressZero()) {
            vault.settleFor{value: amount}(address(marginCore));
        } else {
            vault.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(vault), amount);
            vault.settleFor(address(marginCore));
        }
    }
}
