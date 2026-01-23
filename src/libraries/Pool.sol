// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {InsuranceFunds, toInsuranceFunds} from "../types/InsuranceFunds.sol";
import {FeeTypes} from "../types/FeeTypes.sol";
import {MarginActions} from "../types/MarginActions.sol";
import {MarginState} from "../types/MarginState.sol";
import {MarginBalanceDelta} from "../types/MarginBalanceDelta.sol";
import {ReservesType, Reserves, toReserves, ReservesLibrary} from "../types/Reserves.sol";
import {Slot0} from "../types/Slot0.sol";
import {CustomRevert} from "./CustomRevert.sol";
import {FeeLibrary} from "./FeeLibrary.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {Math} from "./Math.sol";
import {PairPosition} from "./PairPosition.sol";
import {LendPosition} from "./LendPosition.sol";
import {PerLibrary} from "./PerLibrary.sol";
import {ProtocolFeeLibrary} from "./ProtocolFeeLibrary.sol";
import {TimeLibrary} from "./TimeLibrary.sol";
import {SafeCast} from "./SafeCast.sol";
import {SwapMath} from "./SwapMath.sol";
import {InterestMath} from "./InterestMath.sol";
import {PriceMath} from "./PriceMath.sol";

/// @title A library for managing Likwid pools.
/// @notice This library contains all the functions for interacting with a Likwid pool.
library Pool {
    using CustomRevert for bytes4;
    using SafeCast for *;
    using SwapMath for *;
    using FeeLibrary for uint24;
    using PerLibrary for uint256;
    using TimeLibrary for uint32;
    using Pool for State;
    using PairPosition for PairPosition.State;
    using PairPosition for mapping(bytes32 => PairPosition.State);
    using LendPosition for LendPosition.State;
    using LendPosition for mapping(bytes32 => LendPosition.State);
    using ProtocolFeeLibrary for uint24;

    error InvalidFee();

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when trying to remove more liquidity than available in the pool
    error InsufficientLiquidity();

    error InsufficientAmount();

    error InconsistentReserves();

    uint128 internal constant INITIAL_LIQUIDITY = 1000;
    uint8 internal constant DEFAULT_INSURANCE_FUND_PERCENTAGE = 30; // 30%

    struct State {
        Slot0 slot0;
        /// @notice The cumulative borrow rate of the first currency in the pool.
        uint256 borrow0CumulativeLast;
        /// @notice The cumulative borrow rate of the second currency in the pool.
        uint256 borrow1CumulativeLast;
        /// @notice The cumulative deposit rate of the first currency in the pool.
        uint256 deposit0CumulativeLast;
        /// @notice The cumulative deposit rate of the second currency in the pool.
        uint256 deposit1CumulativeLast;
        Reserves realReserves;
        Reserves mirrorReserves;
        Reserves pairReserves;
        Reserves truncatedReserves;
        Reserves lendReserves;
        Reserves interestReserves;
        /// @notice The reserves allocated for protocol interest
        Reserves protocolInterestReserves;
        Reserves insuranceFundUpperLimit;
        InsuranceFunds insuranceFunds;
        /// @notice The positions in the pool, mapped by a hash of the owner's address and a salt.
        mapping(bytes32 positionKey => PairPosition.State) positions;
        mapping(bytes32 positionKey => LendPosition.State) lendPositions;
    }

    struct ModifyLiquidityParams {
        // the address that owns the position
        address owner;
        uint256 amount0;
        uint256 amount1;
        // any change in liquidity
        int128 liquidityDelta;
        // used to distinguish positions of the same owner, at the same tick range
        bytes32 salt;
    }

    /// @notice Initializes the pool with a given fee
    /// @param self The pool state
    /// @param lpFee The initial fee for the pool
    /// @param marginFee The initial margin fee for the pool
    function initialize(State storage self, uint24 lpFee, uint24 marginFee) internal {
        if (self.borrow0CumulativeLast != 0) PoolAlreadyInitialized.selector.revertWith();
        if (lpFee >= PerLibrary.ONE_MILLION || marginFee >= PerLibrary.ONE_MILLION) {
            InvalidFee.selector.revertWith();
        }

        self.slot0 = Slot0.wrap(bytes32(0)).setLastUpdated(uint32(block.timestamp)).setLpFee(lpFee)
            .setMarginFee(marginFee).setInsuranceFundPercentage(DEFAULT_INSURANCE_FUND_PERCENTAGE);
        self.borrow0CumulativeLast = FixedPoint96.Q96;
        self.borrow1CumulativeLast = FixedPoint96.Q96;
        self.deposit0CumulativeLast = FixedPoint96.Q96;
        self.deposit1CumulativeLast = FixedPoint96.Q96;
    }

    /// @notice Sets the protocol fee for the pool
    /// @param self The pool state
    /// @param protocolFee The new protocol fee
    function setProtocolFee(State storage self, uint24 protocolFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setProtocolFee(protocolFee);
    }

    /// @notice Sets the insurance fund percentage for the pool
    /// @param self The pool state
    /// @param insuranceFundPercentage The new insurance fund percentage
    function setInsuranceFundPercentage(State storage self, uint8 insuranceFundPercentage) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setInsuranceFundPercentage(insuranceFundPercentage);
    }

    /// @notice Adds or removes liquidity from the pool
    /// @param self The pool state
    /// @param params The parameters for modifying liquidity
    /// @return delta The change in balances
    function modifyLiquidity(State storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta, int128 finalLiquidityDelta)
    {
        if (params.liquidityDelta == 0 && params.amount0 == 0 && params.amount1 == 0) {
            return (BalanceDelta.wrap(0), 0);
        }

        Slot0 _slot0 = self.slot0;
        Reserves _pairReserves = self.pairReserves;

        (uint128 _reserve0, uint128 _reserve1) = _pairReserves.reserves();
        uint128 totalSupply = _slot0.totalSupply();

        if (params.liquidityDelta < 0) {
            // --- Remove Liquidity ---
            uint256 liquidityToRemove = uint256(-int256(params.liquidityDelta));
            if (liquidityToRemove > totalSupply) InsufficientLiquidity.selector.revertWith();

            uint256 amount0Out = Math.mulDiv(liquidityToRemove, _reserve0, totalSupply);
            uint256 amount1Out = Math.mulDiv(liquidityToRemove, _reserve1, totalSupply);

            delta = toBalanceDelta(amount0Out.toInt128(), amount1Out.toInt128());
            self.slot0 = _slot0.setTotalSupply(totalSupply - liquidityToRemove.toUint128());
            finalLiquidityDelta = params.liquidityDelta;
        } else {
            // --- Add Liquidity ---
            uint256 amount0In;
            uint256 amount1In;
            uint256 liquidityAdded;

            if (totalSupply == 0) {
                totalSupply = INITIAL_LIQUIDITY; // Initial liquidity boost to prevent precision issues
                amount0In = params.amount0;
                amount1In = params.amount1;
                liquidityAdded = Math.sqrt(amount0In * amount1In);
            } else {
                uint256 amount1FromAmount0 = Math.mulDiv(params.amount0, _reserve1, _reserve0);
                if (amount1FromAmount0 <= params.amount1) {
                    amount0In = params.amount0;
                    amount1In = amount1FromAmount0;
                } else {
                    amount0In = Math.mulDiv(params.amount1, _reserve0, _reserve1);
                    amount1In = params.amount1;
                }
                liquidityAdded = Math.min(
                    Math.mulDiv(amount0In, totalSupply, _reserve0), Math.mulDiv(amount1In, totalSupply, _reserve1)
                );
            }

            delta = toBalanceDelta(-amount0In.toInt128(), -amount1In.toInt128());

            self.slot0 = _slot0.setTotalSupply(totalSupply + liquidityAdded.toUint128());
            finalLiquidityDelta = liquidityAdded.toInt128();
        }
        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](2);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, delta);
        deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, delta);
        self.updateReserves(deltaParams);

        self.positions.get(params.owner, params.salt).update(finalLiquidityDelta, delta);
        // Initialize truncated reserves if not set
        if (self.truncatedReserves == ReservesLibrary.ZERO_RESERVES) {
            self.truncatedReserves = self.pairReserves;
        }
    }

    struct SwapParams {
        address sender;
        // zeroForOne Whether to swap token0 for token1
        bool zeroForOne;
        // The amount to swap, negative for exact input, positive for exact output
        int256 amountSpecified;
        // Whether to use the mirror reserves for the swap
        bool useMirror;
        bytes32 salt;
    }

    /// @notice Swaps tokens in the pool
    /// @param self The pool state
    /// @param params The parameters for the swap
    /// @return swapDelta The change in balances
    /// @return amountToProtocol The amount of fees to be sent to the protocol
    /// @return swapFee The fee for the swap
    /// @return feeAmount The total fee amount for the swap.
    function swap(State storage self, SwapParams memory params, uint24 defaultProtocolFee)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, uint256 feeAmount)
    {
        Reserves _pairReserves = self.pairReserves;
        Reserves _truncatedReserves = self.truncatedReserves;
        Slot0 _slot0 = self.slot0;
        uint24 _lpFee = _slot0.lpFee();

        bool exactIn = params.amountSpecified < 0;

        uint256 amountIn;
        uint256 amountOut;

        if (exactIn) {
            amountIn = uint256(-params.amountSpecified);
            (amountOut, swapFee, feeAmount) =
                SwapMath.getAmountOut(_pairReserves, _truncatedReserves, _lpFee, params.zeroForOne, amountIn);
        } else {
            amountOut = uint256(params.amountSpecified);
            (amountIn, swapFee, feeAmount) =
                SwapMath.getAmountIn(_pairReserves, _truncatedReserves, _lpFee, params.zeroForOne, amountOut);
        }

        (amountToProtocol, feeAmount) =
            ProtocolFeeLibrary.splitFee(_slot0.protocolFee(defaultProtocolFee), FeeTypes.SWAP, feeAmount);

        int128 amount0Delta;
        int128 amount1Delta;
        BalanceDelta protocolFeeDelta;

        if (params.zeroForOne) {
            amount0Delta = -amountIn.toInt128();
            amount1Delta = amountOut.toInt128();
            protocolFeeDelta = toBalanceDelta(amountToProtocol.toInt128(), 0);
        } else {
            amount0Delta = amountOut.toInt128();
            amount1Delta = -amountIn.toInt128();
            protocolFeeDelta = toBalanceDelta(0, amountToProtocol.toInt128());
        }

        ReservesLibrary.UpdateParam[] memory deltaParams;
        swapDelta = toBalanceDelta(amount0Delta, amount1Delta);
        if (!params.useMirror) {
            BalanceDelta changeDelta = swapDelta + protocolFeeDelta;
            deltaParams = new ReservesLibrary.UpdateParam[](2);
            deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, changeDelta);
            deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, changeDelta);
        } else {
            deltaParams = new ReservesLibrary.UpdateParam[](3);
            BalanceDelta realDelta;
            BalanceDelta lendDelta;
            if (params.zeroForOne) {
                realDelta = toBalanceDelta(amount0Delta, 0);
                lendDelta = toBalanceDelta(0, -amount1Delta);
            } else {
                realDelta = toBalanceDelta(0, amount1Delta);
                lendDelta = toBalanceDelta(-amount0Delta, 0);
            }
            deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, realDelta + protocolFeeDelta);
            // pair MIRROR<=>lend MIRROR
            deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.LEND, lendDelta);
            deltaParams[2] = ReservesLibrary.UpdateParam(ReservesType.PAIR, swapDelta + protocolFeeDelta);
            uint256 depositCumulativeLast;
            if (params.zeroForOne) {
                depositCumulativeLast = self.deposit1CumulativeLast;
            } else {
                depositCumulativeLast = self.deposit0CumulativeLast;
            }
            self.lendPositions.get(params.sender, params.zeroForOne, params.salt)
                .update(params.zeroForOne, depositCumulativeLast, lendDelta);
        }
        self.updateReserves(deltaParams);
    }

    function donate(State storage self, uint256 amount0, uint256 amount1) internal returns (BalanceDelta delta) {
        if (amount0 == 0 && amount1 == 0) {
            return BalanceDelta.wrap(0);
        }
        self.insuranceFunds = self.insuranceFunds + toInsuranceFunds(amount0.toInt128(), amount1.toInt128());
        delta = toBalanceDelta(-amount0.toInt128(), -amount1.toInt128());
        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](1);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, delta);
        self.updateReserves(deltaParams);
    }

    struct LendParams {
        address sender;
        /// False if lend token0,true if lend token1
        bool lendForOne;
        /// The amount to lend, negative for deposit, positive for withdraw
        int128 lendAmount;
        bytes32 salt;
    }

    /// @notice Lends tokens to the pool.
    /// @param self The pool state.
    /// @param params The parameters for the lending operation.
    /// @return lendDelta The change in the lender's balance.
    /// @return depositCumulativeLast The last cumulative deposit rate.
    function lend(State storage self, LendParams memory params)
        internal
        returns (BalanceDelta lendDelta, uint256 depositCumulativeLast)
    {
        int128 amount0Delta;
        int128 amount1Delta;

        if (params.lendForOne) {
            amount1Delta = params.lendAmount;
            depositCumulativeLast = self.deposit1CumulativeLast;
        } else {
            amount0Delta = params.lendAmount;
            depositCumulativeLast = self.deposit0CumulativeLast;
        }

        lendDelta = toBalanceDelta(amount0Delta, amount1Delta);
        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](2);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, lendDelta);
        deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.LEND, lendDelta);
        self.updateReserves(deltaParams);

        self.lendPositions.get(params.sender, params.lendForOne, params.salt)
            .update(params.lendForOne, depositCumulativeLast, lendDelta);
    }

    function margin(State storage self, MarginBalanceDelta memory params, uint24 defaultProtocolFee)
        internal
        returns (
            BalanceDelta marginDelta,
            uint256 marginToProtocol,
            uint256 swapToProtocol,
            uint256 protocolInterest0,
            uint256 protocolInterest1
        )
    {
        if (
            (params.action != MarginActions.CLOSE && params.action != MarginActions.LIQUIDATE_BURN)
                && params.marginDelta == BalanceDeltaLibrary.ZERO_DELTA
        ) {
            InsufficientAmount.selector.revertWith();
        }
        Slot0 _slot0 = self.slot0;
        marginDelta = params.marginDelta;
        bool isMargin = params.action == MarginActions.MARGIN;
        if (isMargin) {
            (marginToProtocol, params.marginFeeAmount) = ProtocolFeeLibrary.splitFee(
                _slot0.protocolFee(defaultProtocolFee), FeeTypes.MARGIN, params.marginFeeAmount
            );
        }
        (swapToProtocol, params.swapFeeAmount) =
            ProtocolFeeLibrary.splitFee(_slot0.protocolFee(defaultProtocolFee), FeeTypes.SWAP, params.swapFeeAmount);

        BalanceDelta protocolDelta;
        int128 amount0Delta;
        int128 amount1Delta;
        if (params.marginForOne) {
            if (isMargin) {
                amount0Delta = swapToProtocol.toInt128();
                amount1Delta = marginToProtocol.toInt128();
            } else {
                amount1Delta = swapToProtocol.toInt128();
            }
        } else {
            if (isMargin) {
                amount0Delta = marginToProtocol.toInt128();
                amount1Delta = swapToProtocol.toInt128();
            } else {
                amount0Delta = swapToProtocol.toInt128();
            }
        }
        protocolDelta = toBalanceDelta(amount0Delta, amount1Delta);
        ReservesLibrary.UpdateParam[] memory deltaParams = new ReservesLibrary.UpdateParam[](4);
        deltaParams[0] = ReservesLibrary.UpdateParam(ReservesType.REAL, marginDelta + protocolDelta);
        deltaParams[1] = ReservesLibrary.UpdateParam(ReservesType.PAIR, params.pairDelta + protocolDelta);
        deltaParams[2] = ReservesLibrary.UpdateParam(ReservesType.LEND, params.lendDelta);
        deltaParams[3] = ReservesLibrary.UpdateParam(ReservesType.MIRROR, params.mirrorDelta);
        (protocolInterest0, protocolInterest1) =
            self.updateReserves(deltaParams, InsuranceFunds.wrap(BalanceDelta.unwrap(params.fundsDelta)));
    }

    /// @notice Reverts if the given pool has not been initialized
    /// @param self The pool state
    function checkPoolInitialized(State storage self) internal view {
        if (self.borrow0CumulativeLast == 0) PoolNotInitialized.selector.revertWith();
    }

    /// @notice Updates the interest rates for the pool.
    /// @param self The pool state.
    /// @param marginState The current rate state.
    /// @return pairInterest0 The interest earned by the pair for token0.
    /// @return pairInterest1 The interest earned by the pair for token1.
    function updateInterests(State storage self, MarginState marginState, uint24 defaultProtocolFee)
        internal
        returns (uint256 pairInterest0, uint256 pairInterest1, uint256 protocolInterest0, uint256 protocolInterest1)
    {
        Slot0 _slot0 = self.slot0;
        uint256 timeElapsed = _slot0.lastUpdated().getTimeElapsed();
        if (timeElapsed == 0) return (0, 0, 0, 0);

        uint24 protocolFee = _slot0.protocolFee(defaultProtocolFee);

        Reserves _realReserves = self.realReserves;
        Reserves _mirrorReserves = self.mirrorReserves;
        Reserves _interestReserves = self.interestReserves;
        Reserves _protocolInterestReserves = self.protocolInterestReserves;
        Reserves _pairReserves = self.pairReserves;
        Reserves _lendReserves = self.lendReserves;

        uint256 borrow0CumulativeBefore = self.borrow0CumulativeLast;
        uint256 borrow1CumulativeBefore = self.borrow1CumulativeLast;

        (uint256 borrow0CumulativeLast, uint256 borrow1CumulativeLast) = InterestMath.getBorrowRateCumulativeLast(
            timeElapsed, borrow0CumulativeBefore, borrow1CumulativeBefore, marginState, _realReserves, _mirrorReserves
        );
        (uint256 pairReserve0, uint256 pairReserve1) = _pairReserves.reserves();
        (uint256 lendReserve0, uint256 lendReserve1) = _lendReserves.reserves();
        (uint256 mirrorReserve0, uint256 mirrorReserve1) = _mirrorReserves.reserves();
        (uint256 interestReserve0, uint256 interestReserve1) = _interestReserves.reserves();
        (uint256 protocolInterestReserve0, uint256 protocolInterestReserve1) = _protocolInterestReserves.reserves();

        InterestMath.InterestUpdateResult memory result0 = InterestMath.updateInterestForOne(
            InterestMath.InterestUpdateParams({
                mirrorReserve: mirrorReserve0,
                borrowCumulativeLast: borrow0CumulativeLast,
                borrowCumulativeBefore: borrow0CumulativeBefore,
                interestReserve: interestReserve0,
                pairReserve: pairReserve0,
                lendReserve: lendReserve0,
                protocolInterestReserve: protocolInterestReserve0,
                depositCumulativeLast: self.deposit0CumulativeLast,
                protocolFee: protocolFee
            })
        );

        if (result0.changed) {
            mirrorReserve0 = result0.newMirrorReserve;
            pairReserve0 = result0.newPairReserve;
            lendReserve0 = result0.newLendReserve;
            self.deposit0CumulativeLast = result0.newDepositCumulativeLast;
            protocolInterestReserve0 = result0.newProtocolInterestReserve;
            protocolInterest0 = result0.protocolInterest;
            pairInterest0 = result0.pairInterest;
        }

        InterestMath.InterestUpdateResult memory result1 = InterestMath.updateInterestForOne(
            InterestMath.InterestUpdateParams({
                mirrorReserve: mirrorReserve1,
                borrowCumulativeLast: borrow1CumulativeLast,
                borrowCumulativeBefore: borrow1CumulativeBefore,
                interestReserve: interestReserve1,
                pairReserve: pairReserve1,
                lendReserve: lendReserve1,
                protocolInterestReserve: protocolInterestReserve1,
                depositCumulativeLast: self.deposit1CumulativeLast,
                protocolFee: protocolFee
            })
        );

        if (result1.changed) {
            mirrorReserve1 = result1.newMirrorReserve;
            pairReserve1 = result1.newPairReserve;
            lendReserve1 = result1.newLendReserve;
            self.deposit1CumulativeLast = result1.newDepositCumulativeLast;
            protocolInterestReserve1 = result1.newProtocolInterestReserve;
            protocolInterest1 = result1.protocolInterest;
            pairInterest1 = result1.pairInterest;
        }

        if (result0.changed || result1.changed) {
            _pairReserves = toReserves(pairReserve0.toUint128(), pairReserve1.toUint128());
            self.pairReserves = _pairReserves;
            self.mirrorReserves = toReserves(mirrorReserve0.toUint128(), mirrorReserve1.toUint128());
            self.lendReserves = toReserves(lendReserve0.toUint128(), lendReserve1.toUint128());
            self.protocolInterestReserves =
                toReserves(protocolInterestReserve0.toUint128(), protocolInterestReserve1.toUint128());
        }
        Reserves _truncatedReserves = self.truncatedReserves;
        self.truncatedReserves =
            PriceMath.transferReserves(_truncatedReserves, _pairReserves, timeElapsed, marginState.priceMoveSpeedPPM());
        if (borrow0CumulativeBefore < borrow0CumulativeLast) {
            self.borrow0CumulativeLast = borrow0CumulativeLast;
        }
        if (borrow1CumulativeBefore < borrow1CumulativeLast) {
            self.borrow1CumulativeLast = borrow1CumulativeLast;
        }
        if (interestReserve0 != result0.newInterestReserve || interestReserve1 != result1.newInterestReserve) {
            self.interestReserves =
                toReserves(result0.newInterestReserve.toUint128(), result1.newInterestReserve.toUint128());
        }

        self.slot0 = self.slot0.setLastUpdated(uint32(block.timestamp));
    }

    /// @notice Updates the reserves of the pool.
    /// @param self The pool state.
    /// @param params An array of parameters for updating the reserves.
    /// @param fundsDelta The input change in insurance funds.
    function updateReserves(State storage self, ReservesLibrary.UpdateParam[] memory params, InsuranceFunds fundsDelta)
        internal
        returns (uint256 protocolInterest0, uint256 protocolInterest1)
    {
        if (params.length == 0) return (protocolInterest0, protocolInterest1);
        Reserves _realReserves = self.realReserves;
        Reserves _mirrorReserves = self.mirrorReserves;
        Reserves _pairReserves = self.pairReserves;
        Reserves _lendReserves = self.lendReserves;
        Reserves _protocolInterestReserves = self.protocolInterestReserves;
        BalanceDelta _realOddDelta = BalanceDelta.wrap(0);
        for (uint256 i = 0; i < params.length; i++) {
            ReservesType _type = params[i]._type;
            BalanceDelta delta = params[i].delta;
            if (_type == ReservesType.REAL) {
                _realReserves = _realReserves.applyDelta(delta);
            } else if (_type == ReservesType.MIRROR) {
                int128 d0 = delta.amount0();
                int128 d1 = delta.amount1();

                (uint128 mirror0, uint128 mirror1) = _mirrorReserves.reserves();
                (uint128 pInterest0, uint128 pInterest1) = _protocolInterestReserves.reserves();

                if (d0 > 0) {
                    uint256 amount = uint256(uint128(d0));
                    uint256 total = uint256(mirror0) + pInterest0;
                    if (total > 0) {
                        if (amount <= total) {
                            uint256 mirrorPart = Math.mulDiv(amount, mirror0, total);
                            uint256 pInterestPart = amount - mirrorPart;
                            _realOddDelta = _realOddDelta + toBalanceDelta(pInterestPart.toInt128(), 0);
                            mirror0 -= mirrorPart.toUint128();
                            pInterest0 -= pInterestPart.toUint128();
                            protocolInterest0 += pInterestPart;
                        } else {
                            _realOddDelta = _realOddDelta + toBalanceDelta(pInterest0.toInt128(), 0);
                            fundsDelta = fundsDelta + toInsuranceFunds((amount - total).toInt128(), 0);
                            protocolInterest0 += pInterest0;
                            mirror0 = 0;
                            pInterest0 = 0;
                        }
                    } else {
                        _realOddDelta = _realOddDelta + toBalanceDelta(d0, 0);
                    }
                } else if (d0 < 0) {
                    mirror0 += uint128(-d0);
                }

                if (d1 > 0) {
                    uint256 amount = uint256(uint128(d1));
                    uint256 total = uint256(mirror1) + pInterest1;
                    if (total > 0) {
                        if (amount <= total) {
                            uint256 mirrorPart = Math.mulDiv(amount, mirror1, total);
                            uint256 pInterestPart = amount - mirrorPart;
                            _realOddDelta = _realOddDelta + toBalanceDelta(0, pInterestPart.toInt128());
                            mirror1 -= mirrorPart.toUint128();
                            pInterest1 -= pInterestPart.toUint128();
                            protocolInterest1 += pInterestPart;
                        } else {
                            _realOddDelta = _realOddDelta + toBalanceDelta(0, pInterest1.toInt128());
                            fundsDelta = fundsDelta + toInsuranceFunds(0, (amount - total).toInt128());
                            protocolInterest1 += pInterest1;
                            mirror1 = 0;
                            pInterest1 = 0;
                        }
                    } else {
                        _realOddDelta = _realOddDelta + toBalanceDelta(0, d1);
                    }
                } else if (d1 < 0) {
                    mirror1 += uint128(-d1);
                }

                _mirrorReserves = toReserves(mirror0, mirror1);
                _protocolInterestReserves = toReserves(pInterest0, pInterest1);
            } else if (_type == ReservesType.PAIR) {
                _pairReserves = _pairReserves.applyDelta(delta);
            } else if (_type == ReservesType.LEND) {
                _lendReserves = _lendReserves.applyDelta(delta);
            }
        }
        _realReserves = _realReserves.applyDelta(_realOddDelta);
        Reserves _insuranceFundUpperLimit = self.insuranceFundUpperLimit;

        self._updateReservesConsistent(
            _realReserves, _mirrorReserves, _pairReserves, _lendReserves, _insuranceFundUpperLimit, fundsDelta
        );

        self.protocolInterestReserves = _protocolInterestReserves;
    }

    function updateReserves(State storage self, ReservesLibrary.UpdateParam[] memory params)
        internal
        returns (uint256 protocolInterest0, uint256 protocolInterest1)
    {
        return self.updateReserves(params, InsuranceFunds.wrap(0));
    }

    function _distributeExcessFunds(
        int128 currentFund,
        int128 fundDelta,
        uint256 limit,
        uint128 pairReserve,
        uint128 lendReserve
    ) private pure returns (int128 newFund, uint128 pairAdd, uint128 lendAdd) {
        newFund = currentFund + fundDelta;
        if (fundDelta > 0 && newFund > 0) {
            uint128 newFundU = uint128(newFund);
            if (newFundU > limit) {
                uint256 excess = newFundU - limit;
                uint128 fundDeltaU = uint128(fundDelta);
                if (excess > fundDeltaU) {
                    excess = fundDeltaU;
                }

                uint256 totalReserve = uint256(pairReserve) + uint256(lendReserve);
                if (totalReserve > 0) {
                    uint256 pairAddAmount = Math.mulDiv(excess, pairReserve, totalReserve);
                    pairAdd = pairAddAmount.toUint128();
                    lendAdd = (excess - pairAddAmount).toUint128();
                }
                newFund = (newFundU - excess).toInt128();
            }
        }
    }

    function _updateReservesConsistent(
        State storage self,
        Reserves _realReserves,
        Reserves _mirrorReserves,
        Reserves _pairReserves,
        Reserves _lendReserves,
        Reserves _insuranceFundUpperLimit,
        InsuranceFunds fundsDelta
    ) internal {
        InsuranceFunds _insuranceFunds = self.insuranceFunds;
        uint8 insuranceFundPercentage = self.slot0.insuranceFundPercentage();
        Reserves reserves0 = _realReserves + _mirrorReserves;
        (uint256 r0, uint256 r1) = reserves0.reserves();
        (uint256 limit0, uint256 limit1) = _insuranceFundUpperLimit.reserves();
        uint256 newInsuranceFundLimit0 = Math.mulDiv(r0, insuranceFundPercentage, 100);
        uint256 newInsuranceFundLimit1 = Math.mulDiv(r1, insuranceFundPercentage, 100);
        if (limit0 < newInsuranceFundLimit0) {
            limit0 = newInsuranceFundLimit0;
        }
        if (limit1 < newInsuranceFundLimit1) {
            limit1 = newInsuranceFundLimit1;
        }
        _insuranceFundUpperLimit = toReserves(limit0.toUint128(), limit1.toUint128());

        (int128 insuranceFund0, int128 insuranceFund1) = _insuranceFunds.unpack();
        (int128 fundsDelta0, int128 fundsDelta1) = fundsDelta.unpack();

        (uint128 pairR0, uint128 pairR1) = _pairReserves.reserves();
        (uint128 lendR0, uint128 lendR1) = _lendReserves.reserves();

        uint128 pairAdd0;
        uint128 lendAdd0;
        (insuranceFund0, pairAdd0, lendAdd0) =
            _distributeExcessFunds(insuranceFund0, fundsDelta0, limit0, pairR0, lendR0);

        uint128 pairAdd1;
        uint128 lendAdd1;
        (insuranceFund1, pairAdd1, lendAdd1) =
            _distributeExcessFunds(insuranceFund1, fundsDelta1, limit1, pairR1, lendR1);

        if (pairAdd0 > 0 || pairAdd1 > 0) {
            _pairReserves = _pairReserves + toReserves(pairAdd0, pairAdd1);
        }
        if (lendAdd0 > 0 || lendAdd1 > 0) {
            _lendReserves = _lendReserves + toReserves(lendAdd0, lendAdd1);
        }

        _insuranceFunds = toInsuranceFunds(insuranceFund0, insuranceFund1);
        Reserves reserves1 = (_pairReserves + _lendReserves).applyFunds(_insuranceFunds);
        if (reserves0 != reserves1) {
            InconsistentReserves.selector.revertWith();
        }

        self.realReserves = _realReserves;
        self.mirrorReserves = _mirrorReserves;
        self.pairReserves = _pairReserves;
        self.lendReserves = _lendReserves;

        self.insuranceFundUpperLimit = _insuranceFundUpperLimit;
        self.insuranceFunds = _insuranceFunds;
    }
}
