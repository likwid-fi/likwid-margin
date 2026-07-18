// SPDX-License-Identifier: BUSL-1.1
// Likwid Contracts
pragma solidity ^0.8.26;

// Openzeppelin
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
// Local
import {SafeCallback} from "./base/SafeCallback.sol";
import {ERC6909} from "./base/ERC6909.sol";
import {IMarginCore} from "./interfaces/IMarginCore.sol";
import {IMarginRefinancer} from "./interfaces/IMarginRefinancer.sol";
import {IMarginPositionReceiver} from "./interfaces/IMarginPositionReceiver.sol";
import {ILikwidDebtFundingCallback} from "./interfaces/ILikwidDebtFundingCallback.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {IVault} from "./interfaces/IVault.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Math} from "./libraries/Math.sol";
import {MarginPosition} from "./libraries/MarginPosition.sol";
import {PerLibrary} from "./libraries/PerLibrary.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {CurrentStateLibrary} from "./libraries/CurrentStateLibrary.sol";
import {BalanceDelta} from "./types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "./types/Currency.sol";
import {MarginLevels, MarginLevelsLibrary} from "./types/MarginLevels.sol";
import {PoolId} from "./types/PoolId.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {Reserves} from "./types/Reserves.sol";

/// @title Likwid debt market
/// @notice Zero-coupon fixed-rate takeover market for margin debt. Underwriters post quotes
/// without locking capital; when a borrower refinances against a quote, the underwriter's funds
/// repay the position's floating-rate pool debt (mirror becomes real immediately), the borrower
/// owes this contract the face value at maturity, and the underwriter holds a transferable
/// ERC6909 claim on that face value secured by the position's collateral.
contract LikwidDebtMarket is IMarginRefinancer, IMarginPositionReceiver, SafeCallback, ERC6909 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using CustomRevert for bytes4;
    using CurrencyLibrary for Currency;
    using MarginLevelsLibrary for MarginLevels;

    error QuoteExpired();
    error QuoteMismatch();
    error QuoteRateTooHigh();
    error QuoteAmountExceeded();
    error DurationInvalid();
    error InvalidNativeValue();
    error Reentrancy();
    error NotUnderwriter();
    error NoDebt();
    error CollateralLevelTooLow();
    error LoanNotActive();
    error LoanNotDefaulted();
    error LoanRepayWindowClosed();
    error NothingToRedeem();
    error NoExcess();
    error NotMarginCore();
    error SettlementPriceUnavailable();
    error UnexpectedPositionTransfer();

    event QuotePosted(
        uint256 indexed quoteId,
        address indexed underwriter,
        PoolId indexed poolId,
        bool marginForOne,
        uint128 maxAmount,
        uint24 fixedRatePPM,
        uint24 minCollateralLevel,
        uint32 maxDuration,
        uint32 expiry,
        address fundingCallback
    );

    event QuoteCancelled(uint256 indexed quoteId);

    event Refinanced(
        uint256 indexed loanId,
        PoolId indexed poolId,
        address indexed borrower,
        address underwriter,
        uint256 quoteId,
        uint256 principal,
        uint256 faceValue,
        uint256 collateralAmount,
        uint32 maturity
    );

    event LoanRepaid(uint256 indexed loanId, address indexed payer);

    event LoanLiquidated(uint256 indexed loanId, address indexed caller);

    event ClaimRedeemed(uint256 indexed loanId, address indexed holder, uint256 faceAmount, uint256 payout);

    /// @notice Emitted when default settlement opens: claims are capped and any excess
    /// collateral is set aside for the borrower.
    event DefaultSettled(uint256 indexed loanId, uint128 claimableCollateral, uint128 excessCollateral);

    event ExcessClaimed(uint256 indexed loanId, address indexed borrower, uint256 amount);

    /// @notice An underwriter's standing offer to buy margin debt. No capital is locked;
    /// funds are pulled from the underwriter at fill time (requires ERC20 allowance).
    struct Quote {
        address underwriter;
        PoolId poolId;
        /// @notice Position direction the quote accepts (debt currency is the opposite side)
        bool marginForOne;
        /// @notice Remaining principal (debt currency) this quote will fund
        uint128 maxAmount;
        /// @notice Annual fixed rate in millionths
        uint24 fixedRatePPM;
        /// @notice Minimum collateral value at fill, in millionths of the face value
        uint24 minCollateralLevel;
        /// @notice Maximum loan duration in seconds
        uint32 maxDuration;
        /// @notice Quote expiry timestamp
        uint32 expiry;
        /// @notice Optional just-in-time funding source; shortfall falls back to the
        /// underwriter's ERC20 allowance
        address fundingCallback;
    }

    struct Loan {
        address borrower;
        bool repaid;
        bool liquidated;
        /// @notice Position direction: true when the collateral is currency1
        bool marginForOne;
        uint32 maturity;
        Currency debtCurrency;
        Currency collateralCurrency;
        /// @notice Collateral still held for this loan
        uint128 collateralAmount;
        /// @notice Original face value (initial claim supply)
        uint128 faceValue;
        /// @notice Unredeemed claim supply
        uint128 outstandingFace;
        PoolId poolId;
    }

    /// @notice Pre-maturity liquidation threshold: collateral value below this fraction
    /// (in millionths) of the face value opens physical settlement early.
    uint24 public constant LIQUIDATE_LEVEL = 1_050_000; // 105%

    IMarginCore public immutable marginCore;
    /// @notice Wrapped native token used to fund and repay native-currency debt
    IWETH9 public immutable weth;

    uint256 public nextQuoteId = 1;
    uint256 public nextLoanId = 1;
    mapping(uint256 quoteId => Quote) public quotes;
    mapping(uint256 loanId => Loan) public loans;
    /// @notice Whether default settlement (claim cap + borrower excess) has been computed
    mapping(uint256 loanId => bool) public defaultSettled;
    /// @notice Collateral above the claim cap, returned to the borrower via claimExcess
    mapping(uint256 loanId => uint128) public borrowerExcess;

    bool transient locked;
    /// @notice The destination salt armed by prepareRefinance for the current transaction; the
    /// receive hook only accepts a transfer to this exact salt.
    bytes32 transient armedSalt;
    bool transient armed;

    modifier nonReentrant() {
        _enterLock();
        _;
        _exitLock();
    }

    function _enterLock() internal {
        if (locked) Reentrancy.selector.revertWith();
        locked = true;
    }

    function _exitLock() internal {
        locked = false;
    }

    constructor(IVault _vault, IMarginCore _marginCore, IWETH9 _weth) SafeCallback(_vault) {
        marginCore = _marginCore;
        weth = _weth;
    }

    // ******************** QUOTES ********************

    /// @notice Post a standing offer to fund refinancings. Does not lock capital: keep the
    /// debt currency approved to this contract for the quote to be fillable.
    function postQuote(
        PoolId poolId,
        bool marginForOne,
        uint128 maxAmount,
        uint24 fixedRatePPM,
        uint24 minCollateralLevel,
        uint32 maxDuration,
        uint32 expiry,
        address fundingCallback
    ) external returns (uint256 quoteId) {
        if (maxDuration == 0) DurationInvalid.selector.revertWith();
        quoteId = nextQuoteId++;
        quotes[quoteId] = Quote({
            underwriter: msg.sender,
            poolId: poolId,
            marginForOne: marginForOne,
            maxAmount: maxAmount,
            fixedRatePPM: fixedRatePPM,
            minCollateralLevel: minCollateralLevel,
            maxDuration: maxDuration,
            expiry: expiry,
            fundingCallback: fundingCallback
        });
        emit QuotePosted(
            quoteId,
            msg.sender,
            poolId,
            marginForOne,
            maxAmount,
            fixedRatePPM,
            minCollateralLevel,
            maxDuration,
            expiry,
            fundingCallback
        );
    }

    function cancelQuote(uint256 quoteId) external {
        if (quotes[quoteId].underwriter != msg.sender) NotUnderwriter.selector.revertWith();
        delete quotes[quoteId];
        emit QuoteCancelled(quoteId);
    }

    // ******************** REFINANCE ********************

    /// @inheritdoc IMarginRefinancer
    /// @dev Chooses a fresh, unique destination slot (keyed off nextLoanId) and arms it for the
    /// current transaction so only the wrapper's immediately-following transfer is accepted.
    function prepareRefinance(PoolKey calldata, uint256, bytes calldata) external returns (bytes32 salt) {
        salt = keccak256(abi.encodePacked(address(this), nextLoanId));
        armedSalt = salt;
        armed = true;
    }

    /// @inheritdoc IMarginPositionReceiver
    /// @dev Accepts only the slot armed by prepareRefinance in this transaction; any other pushed
    /// transfer reverts, so an attacker cannot pre-occupy the destination slot to grief refinances.
    function onMarginPositionReceived(PoolKey calldata, bytes32 salt, address) external returns (bytes4) {
        if (msg.sender != address(marginCore)) NotMarginCore.selector.revertWith();
        if (!armed || salt != armedSalt) UnexpectedPositionTransfer.selector.revertWith();
        armed = false;
        return IMarginPositionReceiver.onMarginPositionReceived.selector;
    }

    /// @inheritdoc IMarginRefinancer
    /// @dev data = abi.encode(uint256 quoteId, uint24 maxRatePPM, uint32 duration).
    /// The position must already be owned by this contract (transferred by the caller);
    /// its full floating debt is repaid with the underwriter's funds and its collateral is
    /// released into this contract's custody.
    function onRefinance(PoolKey calldata key, bytes32 salt, address borrower, bytes calldata data)
        external
        nonReentrant
    {
        (uint256 quoteId, uint24 maxRatePPM, uint32 duration) = abi.decode(data, (uint256, uint24, uint32));

        PoolId poolId = key.toId();
        Quote memory quote = quotes[quoteId];
        if (quote.expiry < block.timestamp || quote.underwriter == address(0)) QuoteExpired.selector.revertWith();
        if (PoolId.unwrap(quote.poolId) != PoolId.unwrap(poolId)) QuoteMismatch.selector.revertWith();
        if (quote.fixedRatePPM > maxRatePPM) QuoteRateTooHigh.selector.revertWith();
        if (duration == 0 || duration > quote.maxDuration) DurationInvalid.selector.revertWith();

        MarginPosition.State memory position = marginCore.getPositionState(poolId, address(this), salt);
        if (position.debtAmount == 0) NoDebt.selector.revertWith();
        if (position.marginForOne != quote.marginForOne) QuoteMismatch.selector.revertWith();

        (Currency debtCurrency, Currency collateralCurrency) =
            position.marginForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 principal = position.debtAmount;
        if (principal > quote.maxAmount) QuoteAmountExceeded.selector.revertWith();
        quotes[quoteId].maxAmount = quote.maxAmount - principal.toUint128();

        // Source the underwriter's funds (callback first, allowance for any shortfall),
        // then repay the pool debt inside our own unlock. Native debt is funded in the
        // wrapped token and unwrapped for settlement.
        _sourceFunds(quoteId, quote, _fundingToken(debtCurrency), principal);
        if (debtCurrency.isAddressZero()) {
            weth.withdraw(principal);
        }
        bytes memory result = vault.unlock(abi.encode(key, salt, principal));
        (uint256 releaseAmount, uint256 realRepayAmount) = abi.decode(result, (uint256, uint256));

        uint128 faceValue = (
            realRepayAmount
                + Math.mulDiv(
                    realRepayAmount, uint256(quote.fixedRatePPM) * duration, PerLibrary.ONE_MILLION * 365 days
                )
        ).toUint128();

        // The underwriter prices its own risk: collateral must be worth at least
        // minCollateralLevel of the face value at fill time.
        if (
            _collateralValueInDebt(_truncatedReserves(poolId), position.marginForOne, releaseAmount)
                < Math.mulDiv(faceValue, quote.minCollateralLevel, PerLibrary.ONE_MILLION)
        ) {
            CollateralLevelTooLow.selector.revertWith();
        }

        uint256 loanId = nextLoanId++;
        uint32 maturity = uint32(block.timestamp) + duration;
        loans[loanId] = Loan({
            borrower: borrower,
            repaid: false,
            liquidated: false,
            marginForOne: position.marginForOne,
            maturity: maturity,
            debtCurrency: debtCurrency,
            collateralCurrency: collateralCurrency,
            collateralAmount: releaseAmount.toUint128(),
            faceValue: faceValue,
            outstandingFace: faceValue,
            poolId: poolId
        });
        _mint(quote.underwriter, loanId, faceValue);

        emit Refinanced(
            loanId, poolId, borrower, quote.underwriter, quoteId, realRepayAmount, faceValue, releaseAmount, maturity
        );
    }

    /// @dev Repays the position's full debt: settles the debt currency we hold into the vault
    /// credited to the margin core, and receives the released collateral.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        (PoolKey memory key, bytes32 salt, uint256 principal) = abi.decode(rawData, (PoolKey, bytes32, uint256));

        (uint256 releaseAmount, uint256 realRepayAmount, BalanceDelta delta) =
            marginCore.repay(key, salt, principal, address(this));

        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            _settleFor(key.currency0, uint128(-amount0));
        }
        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            _settleFor(key.currency1, uint128(-amount1));
        }

        return abi.encode(releaseAmount, realRepayAmount);
    }

    function _settleFor(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) {
            vault.settleFor{value: amount}(address(marginCore));
        } else {
            vault.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(vault), amount);
            vault.settleFor(address(marginCore));
        }
    }

    /// @dev The ERC20 used to fund a debt currency: the currency itself, or the wrapped
    /// native token when the debt currency is native.
    function _fundingToken(Currency debtCurrency) internal view returns (address) {
        return debtCurrency.isAddressZero() ? address(weth) : Currency.unwrap(debtCurrency);
    }

    /// @dev Sources `amount` of fundingToken: asks the quote's funding callback to deliver
    /// first (best effort), then pulls any shortfall from the underwriter's allowance.
    /// Reentrancy into this contract from the callback is blocked by the nonReentrant locks.
    function _sourceFunds(uint256 quoteId, Quote memory quote, address fundingToken, uint256 amount) internal {
        uint256 shortfall = amount;
        if (quote.fundingCallback != address(0) && quote.fundingCallback.code.length > 0) {
            uint256 balanceBefore = IERC20(fundingToken).balanceOf(address(this));
            try ILikwidDebtFundingCallback(quote.fundingCallback).likwidDebtMarketFunding(
                quoteId, fundingToken, amount
            ) {
                uint256 delivered = IERC20(fundingToken).balanceOf(address(this)) - balanceBefore;
                shortfall = delivered >= amount ? 0 : amount - delivered;
            } catch {}
        }
        if (shortfall > 0) {
            IERC20(fundingToken).safeTransferFrom(quote.underwriter, address(this), shortfall);
        }
    }

    // ******************** LOAN LIFECYCLE ********************

    /// @notice Repay the loan's face value and release the collateral to the borrower.
    /// Anyone may pay; only allowed before maturity and before liquidation. Native-currency
    /// debt is paid with msg.value == faceValue, or with the wrapped token when msg.value is 0.
    function repayLoan(uint256 loanId) external payable nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0) || loan.repaid || loan.liquidated) LoanNotActive.selector.revertWith();
        if (block.timestamp > loan.maturity) LoanRepayWindowClosed.selector.revertWith();

        loan.repaid = true;
        if (loan.debtCurrency.isAddressZero()) {
            if (msg.value == 0) {
                IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), loan.faceValue);
                weth.withdraw(loan.faceValue);
            } else if (msg.value != loan.faceValue) {
                InvalidNativeValue.selector.revertWith();
            }
        } else {
            if (msg.value > 0) InvalidNativeValue.selector.revertWith();
            IERC20(Currency.unwrap(loan.debtCurrency)).safeTransferFrom(msg.sender, address(this), loan.faceValue);
        }
        loan.collateralCurrency.transfer(loan.borrower, loan.collateralAmount);
        loan.collateralAmount = 0;

        emit LoanRepaid(loanId, msg.sender);
    }

    /// @notice Open physical settlement before maturity when the collateral no longer covers
    /// LIQUIDATE_LEVEL of the face value (priced against the pool's truncated reserves).
    function liquidateLoan(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.borrower == address(0) || loan.repaid || loan.liquidated) LoanNotActive.selector.revertWith();

        Reserves truncatedReserves = _truncatedReserves(loan.poolId);
        uint256 collateralValue = _collateralValueInDebt(truncatedReserves, loan.marginForOne, loan.collateralAmount);
        if (collateralValue >= Math.mulDiv(loan.faceValue, LIQUIDATE_LEVEL, PerLibrary.ONE_MILLION)) {
            LoanNotDefaulted.selector.revertWith();
        }

        loan.liquidated = true;
        emit LoanLiquidated(loanId, msg.sender);
        _openDefaultSettlement(loanId, loan, truncatedReserves);
    }

    /// @dev Opens default settlement once: claims are capped at faceValue / liquidationRatio
    /// (the same liquidation discount the margin core uses), valued at the pool's current
    /// truncated price; collateral above the cap is set aside for the borrower. The premium
    /// over face compensates claim holders for the settlement-time price gap of real volatility;
    /// price manipulation is already priced out upstream by the pool's dynamic fee.
    /// @dev If no price is available (truncated reserves zero, e.g. pool drained) the settlement
    /// is NOT latched and returns false, so callers must block collateral payouts until a price
    /// returns — otherwise an uncapped redeem during the zero-price window would drain the
    /// borrower's excess. A later call recomputes the cap once a price returns.
    /// @return settled True once the cap has been computed and latched.
    function _openDefaultSettlement(uint256 loanId, Loan storage loan, Reserves truncatedReserves)
        internal
        returns (bool settled)
    {
        if (defaultSettled[loanId]) return true;

        (uint128 reserve0, uint128 reserve1) = truncatedReserves.reserves();
        if (reserve0 == 0 || reserve1 == 0) return false; // no price available yet: do not latch, retry later
        defaultSettled[loanId] = true;

        (uint256 reserveDebt, uint256 reserveCollateral) =
            loan.marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);

        uint24 liquidationRatio = marginCore.marginLevels().liquidationRatio();
        uint256 capDebtValue = Math.mulDiv(loan.faceValue, PerLibrary.ONE_MILLION, liquidationRatio);
        uint256 capCollateral = Math.mulDiv(capDebtValue, reserveCollateral, reserveDebt);

        uint128 excess;
        if (loan.collateralAmount > capCollateral) {
            excess = loan.collateralAmount - capCollateral.toUint128();
            loan.collateralAmount = capCollateral.toUint128();
            borrowerExcess[loanId] = excess;
        }
        emit DefaultSettled(loanId, loan.collateralAmount, excess);
        return true;
    }

    /// @notice Returns the collateral above the claim cap to the borrower after a default.
    /// Callable by anyone; funds always go to the borrower. Opens settlement lazily so the
    /// borrower does not have to wait for a claim holder to redeem first.
    function claimExcess(uint256 loanId) external nonReentrant returns (uint256 amount) {
        Loan storage loan = loans[loanId];
        if (
            loan.borrower != address(0) && !loan.repaid
                && (loan.liquidated || block.timestamp > loan.maturity)
        ) {
            _openDefaultSettlement(loanId, loan, _truncatedReserves(loan.poolId));
        }
        amount = borrowerExcess[loanId];
        if (amount == 0) NoExcess.selector.revertWith();
        borrowerExcess[loanId] = 0;
        loan.collateralCurrency.transfer(loan.borrower, amount);
        emit ExcessClaimed(loanId, loan.borrower, amount);
    }

    /// @notice Redeem claim tokens. After repayment claims redeem 1:1 for the debt currency;
    /// after default (maturity passed unpaid, or liquidation) they redeem pro-rata for the collateral.
    function redeem(uint256 loanId, uint256 faceAmount) external nonReentrant returns (uint256 payout) {
        Loan storage loan = loans[loanId];
        if (faceAmount == 0) NothingToRedeem.selector.revertWith();

        _burn(msg.sender, loanId, faceAmount);

        if (loan.repaid) {
            payout = faceAmount;
            loan.outstandingFace -= faceAmount.toUint128();
            loan.debtCurrency.transfer(msg.sender, payout);
        } else if (loan.liquidated || block.timestamp > loan.maturity) {
            // Only pay out capped collateral: if no price is available to compute the cap,
            // block the redeem rather than distribute the borrower's excess uncapped.
            if (!_openDefaultSettlement(loanId, loan, _truncatedReserves(loan.poolId))) {
                SettlementPriceUnavailable.selector.revertWith();
            }
            payout = Math.mulDiv(loan.collateralAmount, faceAmount, loan.outstandingFace);
            loan.outstandingFace -= faceAmount.toUint128();
            loan.collateralAmount -= payout.toUint128();
            loan.collateralCurrency.transfer(msg.sender, payout);
        } else {
            NothingToRedeem.selector.revertWith();
        }

        emit ClaimRedeemed(loanId, msg.sender, faceAmount, payout);
    }

    /// @dev The pool's current truncated reserves — the manipulation-resistant price source
    /// the margin core also uses for liquidation.
    function _truncatedReserves(PoolId poolId) internal view returns (Reserves) {
        return CurrentStateLibrary.getState(vault, poolId).truncatedReserves;
    }

    /// @dev Values a collateral amount in debt-currency terms against the given truncated reserves.
    function _collateralValueInDebt(Reserves truncatedReserves, bool marginForOne, uint256 collateralAmount)
        internal
        pure
        returns (uint256)
    {
        (uint128 reserve0, uint128 reserve1) = truncatedReserves.reserves();
        (uint256 reserveDebt, uint256 reserveCollateral) =
            marginForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        return Math.mulDiv(collateralAmount, reserveDebt, reserveCollateral);
    }

    receive() external payable {}
}
