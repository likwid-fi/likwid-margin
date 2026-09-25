// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PairPosition} from "../libraries/PairPosition.sol";

interface IPairPositionManager is IERC721 {
    event ModifyLiquidity(
        PoolId indexed poolId,
        uint256 indexed tokenId,
        address indexed sender,
        int128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Return the position with the given ID
    /// @param positionId The ID of the position to retrieve
    /// @return _position The position with the given ID
    function getPositionState(uint256 positionId) external view returns (PairPosition.State memory);

    /// @notice Creates a new liquidity position and adds liquidity to it.
    /// @param key The pool key of the position to create.
    /// @param recipient The address that will receive the position NFT.
    /// @param amount0 The amount of token0 to add.
    /// @param amount1 The amount of token1 to add.
    /// @param amount0Min The minimum amount of token0 to deposit.
    /// @param amount1Min The minimum amount of token1 to deposit.
    /// @param deadline Deadline for the transaction.
    /// @return tokenId The ID of the newly created position.
    /// @return liquidity The amount of liquidity minted for the position.
    function addLiquidity(
        PoolKey memory key,
        address recipient,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external payable returns (uint256 tokenId, uint128 liquidity);

    /// @notice Creates a new liquidity position and adds liquidity to it.
    /// @param tokenId The ID of the position to add liquidity to.
    /// @param amount0 The amount of token0 to add.
    /// @param amount1 The amount of token1 to add.
    /// @param amount0Min The minimum amount of token0 to deposit.
    /// @param amount1Min The minimum amount of token1 to deposit.
    /// @param deadline Deadline for the transaction.
    /// @return liquidity The amount of liquidity minted for the position.
    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external payable returns (uint128 liquidity);

    /// @notice Removes liquidity from an existing position.
    /// @param tokenId The ID of the position to remove liquidity from.
    /// @param liquidity The amount of liquidity to remove.
    /// @param amount0Min The minimum amount of token0 to receive.
    /// @param amount1Min The minimum amount of token1 to receive.
    /// @param deadline Deadline for the transaction.
    /// @return amount0 The amount of token0 received.
    /// @return amount1 The amount of token1 received.
    function removeLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    struct SwapInputParams {
        PoolId poolId;
        bool zeroForOne;
        address to;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 deadline;
    }

    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible.
    /// @param params The parameters for the swap.
    /// @return swapFee The fee paid for the swap.
    /// @return feeAmount The amount of the fee.
    /// @return amountOut The amount of output tokens received.
    function exactInput(SwapInputParams calldata params)
        external
        payable
        returns (uint24 swapFee, uint256 feeAmount, uint256 amountOut);

    struct SwapOutputParams {
        PoolId poolId;
        bool zeroForOne;
        address to;
        uint256 amountInMax;
        uint256 amountOut;
        uint256 deadline;
    }

    /// @notice Swaps as few input tokens as possible for an exact amount of output tokens.
    /// @param params The parameters for the swap.
    /// @return swapFee The fee paid for the swap.
    /// @return feeAmount The amount of the fee.
    /// @return amountIn The amount of input tokens paid.
    function exactOutput(SwapOutputParams calldata params)
        external
        payable
        returns (uint24 swapFee, uint256 feeAmount, uint256 amountIn);

    struct SwapMirrorInputParams {
        PoolId poolId;
        bool zeroForOne;
        /// Receives both the real output and the mirror shares
        address to;
        uint256 amountIn;
        /// Minimum of the whole output, real and mirror together
        uint256 amountOutMin;
        /// The most of the output taken in real currency; the rest comes as mirror shares. 0 for pure mirror.
        /// Capped at the pool's real reserve, so type(uint256).max means "as much real as there is".
        uint256 realOutMax;
        uint256 deadline;
    }

    /// @notice Swaps an exact input, taking up to realOutMax of the output in real currency and the rest as
    /// vault mirror shares
    /// @param params The parameters for the swap.
    /// @return swapFee The fee paid for the swap.
    /// @return feeAmount The amount of the fee.
    /// @return realOut The output paid out in real currency.
    /// @return mirrorOut The output credited as mirror shares.
    /// @return shares The mirror shares minted to params.to.
    function exactInputMirror(SwapMirrorInputParams calldata params)
        external
        payable
        returns (uint24 swapFee, uint256 feeAmount, uint256 realOut, uint256 mirrorOut, uint256 shares);

    struct SwapMirrorOutputParams {
        PoolId poolId;
        bool zeroForOne;
        /// Receives both the real output and the mirror shares
        address to;
        uint256 amountInMax;
        /// The whole output, real and mirror together
        uint256 amountOut;
        /// The most of the output taken in real currency; the rest comes as mirror shares. 0 for pure mirror.
        /// Capped at the pool's real reserve, so type(uint256).max means "as much real as there is".
        uint256 realOutMax;
        uint256 deadline;
    }

    /// @notice Swaps for an exact output, taking up to realOutMax of it in real currency and the rest as vault
    /// mirror shares
    /// @param params The parameters for the swap.
    /// @return swapFee The fee paid for the swap.
    /// @return feeAmount The amount of the fee.
    /// @return amountIn The amount of input tokens paid.
    /// @return realOut The output paid out in real currency.
    /// @return mirrorOut The output credited as mirror shares.
    /// @return shares The mirror shares minted to params.to.
    function exactOutputMirror(SwapMirrorOutputParams calldata params)
        external
        payable
        returns (
            uint24 swapFee,
            uint256 feeAmount,
            uint256 amountIn,
            uint256 realOut,
            uint256 mirrorOut,
            uint256 shares
        );

    /// @notice Redeems the caller's vault mirror shares for real currency
    /// @dev The caller must make this contract an operator of, or approve it for, the shares on the vault
    /// @param poolId The pool the shares belong to
    /// @param redeemForOne False to redeem currency0 shares, true for currency1
    /// @param shares The shares to redeem, type(uint256).max for the caller's whole balance
    /// @param to The address to send the currency to
    /// @param amountMin The minimum amount to receive
    /// @param deadline Deadline for the transaction
    /// @return amount The amount sent to `to`
    function redeemMirror(
        PoolId poolId,
        bool redeemForOne,
        uint256 shares,
        address to,
        uint256 amountMin,
        uint256 deadline
    ) external returns (uint256 amount);

    /// @notice Donate to the insurance fund of a given pool
    /// @param poolId The ID of the pool to donate to
    /// @param amount0 The amount of token0 to donate
    /// @param amount1 The amount of token1 to donate
    /// @param deadline Deadline for the transaction
    function donate(PoolId poolId, uint256 amount0, uint256 amount1, uint256 deadline) external;
}
