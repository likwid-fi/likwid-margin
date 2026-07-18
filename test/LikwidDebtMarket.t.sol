// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {LikwidVault} from "../src/core/LikwidVault.sol";
import {LikwidMarginCore} from "../src/core/LikwidMarginCore.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {LikwidDebtMarket} from "../src/LikwidDebtMarket.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {IMarginCore} from "../src/interfaces/IMarginCore.sol";
import {IMarginRefinancer} from "../src/interfaces/IMarginRefinancer.sol";
import {ILikwidDebtFundingCallback} from "../src/interfaces/ILikwidDebtFundingCallback.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {IBasePositionManager} from "../src/interfaces/IBasePositionManager.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {MarginPosition} from "../src/libraries/MarginPosition.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";

contract LikwidDebtMarketTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidMarginCore marginCore;
    LikwidMarginPosition marginPositionManager;
    LikwidPairPosition pairPositionManager;
    LikwidDebtMarket debtMarket;
    WETH weth;
    PoolKey key;
    PoolKey keyNative;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    address underwriter;

    uint128 constant MARGIN_AMOUNT = 0.1e18;
    uint24 constant FIXED_RATE_PPM = 150_000; // 15% annual
    uint24 constant MIN_COLLATERAL_LEVEL = 1_100_000; // 110%
    uint32 constant DURATION = 30 days;

    function setUp() public {
        vault = new LikwidVault(address(this));
        marginCore = new LikwidMarginCore(address(this), vault);
        marginPositionManager = new LikwidMarginPosition(address(this), vault, marginCore);
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        weth = new WETH();
        debtMarket = new LikwidDebtMarket(vault, marginCore, IWETH9(address(weth)));

        address tokenA = address(new MockERC20("TokenA", "TKNA", 18));
        address tokenB = address(new MockERC20("TokenB", "TKNB", 18));
        (token0, token1) = tokenA < tokenB ? (MockERC20(tokenA), MockERC20(tokenB)) : (MockERC20(tokenB), MockERC20(tokenA));
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        vault.setMarginController(address(marginCore));

        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(marginCore), type(uint256).max);
        token1.approve(address(marginCore), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);
        token0.approve(address(debtMarket), type(uint256).max);
        token1.approve(address(debtMarket), type(uint256).max);

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, marginFee: 3000});
        vault.initialize(key);
        keyNative = PoolKey({currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: currency1, fee: 3000, marginFee: 3000});
        vault.initialize(keyNative);

        token0.mint(address(this), 10e18);
        token1.mint(address(this), 20e18);
        pairPositionManager.addLiquidity(key, address(this), 10e18, 20e18, 0, 0, 10000);
        token1.mint(address(this), 20e18);
        pairPositionManager.addLiquidity{value: 10e18}(keyNative, address(this), 10e18, 20e18, 0, 0, 10000);

        underwriter = makeAddr("underwriter");
        token0.mint(underwriter, 100e18);
        token1.mint(underwriter, 100e18);
        vm.deal(underwriter, 100e18);
        vm.startPrank(underwriter);
        token0.approve(address(debtMarket), type(uint256).max);
        token1.approve(address(debtMarket), type(uint256).max);
        weth.deposit{value: 50e18}();
        weth.approve(address(debtMarket), type(uint256).max);
        vm.stopPrank();
    }

    // ==================== Helpers ====================

    function _createPosition(PoolKey memory k, bool marginForOne) internal returns (uint256 tokenId) {
        if (marginForOne) {
            token1.mint(address(this), MARGIN_AMOUNT);
        } else if (!k.currency0.isAddressZero()) {
            token0.mint(address(this), MARGIN_AMOUNT);
        }
        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: marginForOne,
            leverage: 2,
            marginAmount: MARGIN_AMOUNT,
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });
        uint256 value = (!marginForOne && k.currency0.isAddressZero()) ? MARGIN_AMOUNT : 0;
        (tokenId,,) = marginPositionManager.addMargin{value: value}(k, params);
    }

    function _postQuote(PoolId poolId, bool marginForOne) internal returns (uint256 quoteId) {
        quoteId = _postQuoteWithCallback(poolId, marginForOne, address(0));
    }

    function _postQuoteWithCallback(PoolId poolId, bool marginForOne, address fundingCallback)
        internal
        returns (uint256 quoteId)
    {
        vm.prank(underwriter);
        quoteId = debtMarket.postQuote(
            poolId,
            marginForOne,
            10e18,
            FIXED_RATE_PPM,
            MIN_COLLATERAL_LEVEL,
            DURATION,
            uint32(block.timestamp + 1 days),
            fundingCallback
        );
    }

    function _refinance(uint256 tokenId, uint256 quoteId) internal returns (uint256 loanId) {
        loanId = debtMarket.nextLoanId();
        marginPositionManager.refinance(
            tokenId,
            IMarginRefinancer(address(debtMarket)),
            abi.encode(quoteId, uint24(200_000), DURATION),
            block.timestamp
        );
    }

    function _loan(uint256 loanId)
        internal
        view
        returns (
            address borrower,
            bool repaid,
            bool liquidated,
            uint128 collateralAmount,
            uint128 faceValue,
            uint128 outstandingFace,
            uint32 maturity
        )
    {
        (borrower, repaid, liquidated,, maturity,,, collateralAmount, faceValue, outstandingFace,) =
            debtMarket.loans(loanId);
    }

    function _mirrorReserve1(PoolId poolId) internal view returns (uint128 m1) {
        (, m1) = StateLibrary.getMirrorReserves(vault, poolId).reserves();
    }

    // direct core position for transferPosition unit tests
    function _openCorePosition(bytes32 salt) internal {
        _openCorePositionDir(salt, false);
    }

    function _openCorePositionDir(bytes32 salt, bool marginForOne) internal {
        if (marginForOne) token1.mint(address(this), MARGIN_AMOUNT);
        else token0.mint(address(this), MARGIN_AMOUNT);
        IMarginCore.MarginParams memory params = IMarginCore.MarginParams({
            salt: salt,
            marginForOne: marginForOne,
            leverage: 2,
            marginAmount: MARGIN_AMOUNT,
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this)
        });
        vault.unlock(abi.encode(this.margin_callback.selector, abi.encode(key, params)));
    }

    function margin_callback(PoolKey memory, IMarginCore.MarginParams memory) external pure {}

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector, bytes memory params) = abi.decode(data, (bytes4, bytes));

        if (selector == this.margin_callback.selector) {
            (PoolKey memory _key, IMarginCore.MarginParams memory marginParams) =
                abi.decode(params, (PoolKey, IMarginCore.MarginParams));
            (,, BalanceDelta delta) = marginCore.margin(_key, marginParams);
            if (delta.amount0() < 0) {
                _settleFor(_key.currency0, uint256(uint128(-delta.amount0())));
            }
            if (delta.amount1() < 0) {
                _settleFor(_key.currency1, uint256(uint128(-delta.amount1())));
            }
        } else if (selector == this.swap_callback.selector) {
            (PoolKey memory _key, IVault.SwapParams memory swapParams) =
                abi.decode(params, (PoolKey, IVault.SwapParams));
            (BalanceDelta delta,,) = vault.swap(_key, swapParams);
            if (delta.amount0() < 0) {
                vault.sync(_key.currency0);
                token0.transfer(address(vault), uint256(-int256(delta.amount0())));
                vault.settle();
            } else if (delta.amount0() > 0) {
                vault.take(_key.currency0, address(this), uint256(int256(delta.amount0())));
            }
            if (delta.amount1() < 0) {
                vault.sync(_key.currency1);
                token1.transfer(address(vault), uint256(-int256(delta.amount1())));
                vault.settle();
            } else if (delta.amount1() > 0) {
                vault.take(_key.currency1, address(this), uint256(int256(delta.amount1())));
            }
        }
        return "";
    }

    function swap_callback(PoolKey memory, IVault.SwapParams memory) external pure {}

    function _settleFor(Currency currency, uint256 amount) internal {
        vault.sync(currency);
        MockERC20(Currency.unwrap(currency)).transfer(address(vault), amount);
        vault.settleFor(address(marginCore));
    }

    function _manipulatePrice(bool zeroForOne, uint256 swapAmount) internal {
        if (zeroForOne) {
            token0.mint(address(this), swapAmount);
        } else {
            token1.mint(address(this), swapAmount);
        }
        IVault.SwapParams memory swapParams = IVault.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)
        });
        vault.unlock(abi.encode(this.swap_callback.selector, abi.encode(key, swapParams)));
        skip(1000);
    }

    fallback() external payable {}
    receive() external payable {}

    // ==================== Refinance ====================

    function testRefinance() public {
        uint256 tokenId = _createPosition(key, false);
        PoolId poolId = key.toId();
        skip(1000);

        MarginPosition.State memory position = marginPositionManager.getPositionState(tokenId);
        uint256 debtBefore = position.debtAmount;
        uint256 collateralExpected = uint256(position.marginAmount) + position.marginTotal;
        uint128 mirrorBefore = _mirrorReserve1(poolId);
        assertGt(mirrorBefore, 0, "position should have created mirror");
        uint256 underwriterBalanceBefore = token1.balanceOf(underwriter);

        uint256 quoteId = _postQuote(poolId, false);
        uint256 loanId = _refinance(tokenId, quoteId);

        // mirror converted to real at fill: this was the pool's only margin position
        assertGt(mirrorBefore, 0);
        assertApproxEqAbs(_mirrorReserve1(poolId), 0, 2, "mirror fully repaid");

        // pool-side position is gone
        position = marginPositionManager.getPositionState(tokenId);
        assertEq(position.debtAmount, 0);
        assertEq(position.marginAmount, 0);
        assertEq(position.marginTotal, 0);

        // underwriter paid the principal and holds the claim
        assertApproxEqAbs(underwriterBalanceBefore - token1.balanceOf(underwriter), debtBefore, 2);
        (, bool repaid,, uint128 collateralAmount, uint128 faceValue, uint128 outstandingFace,) = _loan(loanId);
        assertFalse(repaid);
        assertGt(faceValue, debtBefore, "face value includes the fixed interest");
        assertEq(outstandingFace, faceValue);
        assertEq(debtMarket.balanceOf(underwriter, loanId), faceValue);

        // collateral is in the market's custody
        assertApproxEqAbs(collateralAmount, collateralExpected, 2);
        assertGe(token0.balanceOf(address(debtMarket)), collateralAmount);

        // quote capacity reduced
        (,,, uint128 maxAmountLeft,,,,,) = debtMarket.quotes(quoteId);
        assertApproxEqAbs(maxAmountLeft, 10e18 - debtBefore, 2);
    }

    function testRefinance_NativeCollateral() public {
        uint256 tokenId = _createPosition(keyNative, false);
        PoolId poolId = keyNative.toId();
        skip(1000);

        uint256 quoteId = _postQuote(poolId, false);
        uint256 marketBalanceBefore = address(debtMarket).balance;
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,, uint128 collateralAmount,,,) = _loan(loanId);
        assertGt(collateralAmount, 0);
        assertEq(address(debtMarket).balance - marketBalanceBefore, collateralAmount, "native collateral held");
    }

    function testRefinance_Fail_NotOwner() public {
        uint256 tokenId = _createPosition(key, false);
        uint256 quoteId = _postQuote(key.toId(), false);

        vm.startPrank(makeAddr("intruder"));
        vm.expectRevert(IBasePositionManager.NotOwner.selector);
        marginPositionManager.refinance(
            tokenId, IMarginRefinancer(address(debtMarket)), abi.encode(quoteId, uint24(200_000), DURATION), 0
        );
        vm.stopPrank();
    }

    function testRefinance_Fail_RateTooHigh() public {
        uint256 tokenId = _createPosition(key, false);
        uint256 quoteId = _postQuote(key.toId(), false);

        vm.expectRevert(LikwidDebtMarket.QuoteRateTooHigh.selector);
        marginPositionManager.refinance(
            tokenId, IMarginRefinancer(address(debtMarket)), abi.encode(quoteId, uint24(100_000), DURATION), 0
        );
    }

    function testRefinance_Fail_QuoteExpired() public {
        uint256 tokenId = _createPosition(key, false);
        uint256 quoteId = _postQuote(key.toId(), false);
        skip(2 days);

        vm.expectRevert(LikwidDebtMarket.QuoteExpired.selector);
        marginPositionManager.refinance(
            tokenId, IMarginRefinancer(address(debtMarket)), abi.encode(quoteId, uint24(200_000), DURATION), 0
        );
    }

    function testRefinance_Fail_CollateralLevelTooLow() public {
        uint256 tokenId = _createPosition(key, false);
        vm.prank(underwriter);
        uint256 quoteId = debtMarket.postQuote(
            key.toId(), false, 10e18, FIXED_RATE_PPM, 10_000_000, DURATION, uint32(block.timestamp + 1 days), address(0)
        ); // demands 1000% collateral

        vm.expectRevert(LikwidDebtMarket.CollateralLevelTooLow.selector);
        marginPositionManager.refinance(
            tokenId, IMarginRefinancer(address(debtMarket)), abi.encode(quoteId, uint24(200_000), DURATION), 0
        );
    }

    function testRefinance_Fail_DirectionMismatch() public {
        uint256 tokenId = _createPosition(key, false);
        uint256 quoteId = _postQuote(key.toId(), true); // wrong direction

        vm.expectRevert(LikwidDebtMarket.QuoteMismatch.selector);
        marginPositionManager.refinance(
            tokenId, IMarginRefinancer(address(debtMarket)), abi.encode(quoteId, uint24(200_000), DURATION), 0
        );
    }

    // ==================== Loan lifecycle ====================

    function testRepayLoanAndRedeem() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,, uint128 collateralAmount, uint128 faceValue,,) = _loan(loanId);
        token1.mint(address(this), faceValue);
        uint256 collateralBalanceBefore = token0.balanceOf(address(this));

        debtMarket.repayLoan(loanId);

        // borrower got the collateral back
        assertEq(token0.balanceOf(address(this)) - collateralBalanceBefore, collateralAmount);
        (, bool repaid,, uint128 collateralLeft,,,) = _loan(loanId);
        assertTrue(repaid);
        assertEq(collateralLeft, 0);

        // underwriter redeems face value 1:1
        uint256 balanceBefore = token1.balanceOf(underwriter);
        vm.prank(underwriter);
        uint256 payout = debtMarket.redeem(loanId, faceValue);
        assertEq(payout, faceValue);
        assertEq(token1.balanceOf(underwriter) - balanceBefore, faceValue);
        assertEq(debtMarket.balanceOf(underwriter, loanId), 0);
    }

    function testDefaultRedeemsCollateral_CappedWithExcess() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,, uint128 collateralBefore, uint128 faceValue,,) = _loan(loanId);
        skip(DURATION + 1);

        // repay window is closed
        token1.mint(address(this), faceValue);
        vm.expectRevert(LikwidDebtMarket.LoanRepayWindowClosed.selector);
        debtMarket.repayLoan(loanId);

        // settlement: claims are capped at faceValue / liquidationRatio at the truncated price
        uint256 balanceBefore = token0.balanceOf(underwriter);
        vm.prank(underwriter);
        uint256 payout = debtMarket.redeem(loanId, faceValue);
        assertLt(payout, collateralBefore, "claims must be capped");
        assertEq(token0.balanceOf(underwriter) - balanceBefore, payout);

        // payout is worth ~ faceValue / 95% in debt terms at the truncated price
        (uint128 r0, uint128 r1) = StateLibrary.getTruncatedReserves(vault, key.toId()).reserves();
        uint256 payoutInDebt = payout * r1 / r0;
        assertApproxEqRel(payoutInDebt, uint256(faceValue) * 1_000_000 / 950_000, 0.05e18);

        // the excess goes back to the borrower
        uint256 excess = debtMarket.borrowerExcess(loanId);
        assertEq(payout + excess, collateralBefore);
        uint256 borrowerBalanceBefore = token0.balanceOf(address(this));
        uint256 claimed = debtMarket.claimExcess(loanId);
        assertEq(claimed, excess);
        assertEq(token0.balanceOf(address(this)) - borrowerBalanceBefore, excess);

        vm.expectRevert(LikwidDebtMarket.NoExcess.selector);
        debtMarket.claimExcess(loanId);
    }

    function testClaimExcess_BeforeAnyRedeem() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,, uint128 collateralBefore,,,) = _loan(loanId);
        skip(DURATION + 1);

        // the borrower does not need to wait for a claim holder: claimExcess opens settlement
        uint256 borrowerBalanceBefore = token0.balanceOf(address(this));
        uint256 excess = debtMarket.claimExcess(loanId);
        assertGt(excess, 0);
        assertEq(token0.balanceOf(address(this)) - borrowerBalanceBefore, excess);

        // claim holders still redeem the capped remainder afterwards
        (,,, uint128 collateralCapped,, uint128 outstandingFace,) = _loan(loanId);
        assertEq(uint256(collateralCapped) + excess, collateralBefore);
        vm.prank(underwriter);
        uint256 payout = debtMarket.redeem(loanId, outstandingFace);
        assertEq(payout, collateralCapped);
    }

    function testDefaultRedeemsProRata() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,, uint128 collateralAmount, uint128 faceValue,,) = _loan(loanId);

        // underwriter sells half the claim on the secondary market
        address buyer = makeAddr("claimBuyer");
        vm.prank(underwriter);
        debtMarket.transfer(buyer, loanId, faceValue / 2);

        skip(DURATION + 1);

        vm.prank(buyer);
        uint256 payoutBuyer = debtMarket.redeem(loanId, faceValue / 2);
        vm.prank(underwriter);
        uint256 payoutUnderwriter = debtMarket.redeem(loanId, faceValue - faceValue / 2);

        // both claimants split the capped collateral evenly; cap + excess covers everything
        assertApproxEqAbs(payoutBuyer, payoutUnderwriter, 2);
        assertApproxEqAbs(
            payoutBuyer + payoutUnderwriter + debtMarket.borrowerExcess(loanId), collateralAmount, 2
        );
    }

    function testLiquidateLoan() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);
        uint256 loanId = _refinance(tokenId, quoteId);

        // healthy loan cannot be liquidated
        vm.expectRevert(LikwidDebtMarket.LoanNotDefaulted.selector);
        debtMarket.liquidateLoan(loanId);

        // crash the collateral (token0) price
        _manipulatePrice(true, 8e18);

        debtMarket.liquidateLoan(loanId);
        (,, bool liquidated,,, uint128 outstandingFace,) = _loan(loanId);
        assertTrue(liquidated);

        // crashed collateral is worth less than the cap: no excess, claims absorb the loss
        assertEq(debtMarket.borrowerExcess(loanId), 0);

        // claim holder settles physically before maturity
        (,,, uint128 collateralAmount,,,) = _loan(loanId);
        vm.prank(underwriter);
        uint256 payout = debtMarket.redeem(loanId, outstandingFace);
        assertEq(payout, collateralAmount);
    }

    // ==================== Native debt (WETH bridge) ====================

    function testRefinance_NativeDebt() public {
        // marginForOne on the native pool: collateral token1, debt = native ETH
        uint256 tokenId = _createPosition(keyNative, true);
        PoolId poolId = keyNative.toId();
        skip(1000);

        uint256 wethBefore = weth.balanceOf(underwriter);
        uint256 quoteId = _postQuote(poolId, true);
        uint256 loanId = _refinance(tokenId, quoteId);

        (, bool repaid,, uint128 collateralAmount, uint128 faceValue,,) = _loan(loanId);
        assertFalse(repaid);
        assertGt(faceValue, 0);
        assertGt(collateralAmount, 0);
        // the underwriter funded in WETH
        assertGt(wethBefore - weth.balanceOf(underwriter), 0);
        // mirror on the native side is cleared
        (uint128 m0,) = StateLibrary.getMirrorReserves(vault, poolId).reserves();
        assertApproxEqAbs(m0, 0, 2);
    }

    function testRepayNativeDebt_WithValue() public {
        uint256 tokenId = _createPosition(keyNative, true);
        skip(1000);
        uint256 quoteId = _postQuote(keyNative.toId(), true);
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,, uint128 collateralAmount, uint128 faceValue,,) = _loan(loanId);
        uint256 collateralBefore = token1.balanceOf(address(this));
        vm.deal(address(this), faceValue);
        debtMarket.repayLoan{value: faceValue}(loanId);
        assertEq(token1.balanceOf(address(this)) - collateralBefore, collateralAmount);

        // claim redeems in native ETH
        uint256 ethBefore = underwriter.balance;
        vm.prank(underwriter);
        uint256 payout = debtMarket.redeem(loanId, faceValue);
        assertEq(payout, faceValue);
        assertEq(underwriter.balance - ethBefore, faceValue);
    }

    function testRepayNativeDebt_WithWETH() public {
        uint256 tokenId = _createPosition(keyNative, true);
        skip(1000);
        uint256 quoteId = _postQuote(keyNative.toId(), true);
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,, uint128 collateralAmount, uint128 faceValue,,) = _loan(loanId);
        vm.deal(address(this), faceValue);
        weth.deposit{value: faceValue}();
        weth.approve(address(debtMarket), faceValue);

        uint256 collateralBefore = token1.balanceOf(address(this));
        debtMarket.repayLoan(loanId);
        assertEq(token1.balanceOf(address(this)) - collateralBefore, collateralAmount);
    }

    // ==================== Funding callback ====================

    function testCallbackFunding() public {
        MockFundingSource source = new MockFundingSource(debtMarket);
        token1.mint(address(source), 10e18);

        // revoke the underwriter's direct allowance to prove the callback funds the fill
        vm.prank(underwriter);
        token1.approve(address(debtMarket), 0);

        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuoteWithCallback(key.toId(), false, address(source));
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,,, uint128 faceValue,,) = _loan(loanId);
        assertGt(faceValue, 0);
        assertEq(debtMarket.balanceOf(underwriter, loanId), faceValue, "claim still goes to the underwriter");
    }

    function testCallbackFunding_FallbackOnRevert() public {
        MockFundingSource source = new MockFundingSource(debtMarket);
        source.setRevertOnFunding(true); // callback reverts; allowance fallback should kick in

        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 underwriterBalanceBefore = token1.balanceOf(underwriter);
        uint256 quoteId = _postQuoteWithCallback(key.toId(), false, address(source));
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,,, uint128 faceValue,,) = _loan(loanId);
        assertGt(faceValue, 0);
        assertGt(underwriterBalanceBefore - token1.balanceOf(underwriter), 0, "funded from allowance");
    }

    function testCallbackFunding_PartialDeliveryPullsShortfall() public {
        MockFundingSource source = new MockFundingSource(debtMarket);
        token1.mint(address(source), 0.1e18);
        source.setMaxDelivery(0.1e18); // deliver less than the principal

        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 underwriterBalanceBefore = token1.balanceOf(underwriter);
        uint256 quoteId = _postQuoteWithCallback(key.toId(), false, address(source));
        uint256 loanId = _refinance(tokenId, quoteId);

        (,,,, uint128 faceValue,,) = _loan(loanId);
        assertGt(faceValue, 0);
        uint256 pulled = underwriterBalanceBefore - token1.balanceOf(underwriter);
        assertGt(pulled, 0, "shortfall pulled from allowance");
        assertEq(token1.balanceOf(address(source)), 0, "callback delivered its part");
    }

    function testCallbackFunding_ReentrancyBlocked() public {
        MockFundingSource source = new MockFundingSource(debtMarket);
        token1.mint(address(source), 10e18);
        source.setReenter(true);

        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuoteWithCallback(key.toId(), false, address(source));
        _refinance(tokenId, quoteId);

        assertTrue(source.reentryBlocked(), "reentrant call must revert");
    }

    // ==================== transferPosition ====================

    function testTransferPosition() public {
        bytes32 saltA = bytes32(uint256(1));
        _openCorePosition(saltA);

        MarginPosition.State memory before = marginCore.getPositionState(key.toId(), address(this), saltA);
        assertGt(before.debtAmount, 0);

        address receiver = makeAddr("receiver");
        marginCore.transferPosition(key, saltA, receiver, saltA);

        MarginPosition.State memory moved = marginCore.getPositionState(key.toId(), receiver, saltA);
        assertEq(moved.debtAmount, before.debtAmount);
        assertEq(moved.marginAmount, before.marginAmount);
        assertEq(moved.marginTotal, before.marginTotal);

        // source slot is now empty
        vm.expectRevert(IMarginCore.PositionEmpty.selector);
        marginCore.transferPosition(key, saltA, receiver, bytes32(uint256(99)));
    }

    function testTransferPosition_Fail_Occupied() public {
        bytes32 saltA = bytes32(uint256(1));
        bytes32 saltB = bytes32(uint256(2));
        _openCorePosition(saltA);
        skip(1000);
        _openCorePosition(saltB);

        vm.expectRevert(IMarginCore.PositionOccupied.selector);
        marginCore.transferPosition(key, saltA, address(this), saltB);
    }

    function testTransferPosition_Fail_Empty() public {
        vm.expectRevert(IMarginCore.PositionEmpty.selector);
        marginCore.transferPosition(key, bytes32(uint256(7)), makeAddr("receiver"), bytes32(0));
    }

    // ==================== Review regression tests ====================

    /// #1: an attacker cannot pre-seed a hostile position under the NFT wrapper's predictable
    /// next-tokenId slot, because the wrapper does not implement IMarginPositionReceiver.
    function testPreseedAttack_Blocked() public {
        bytes32 attackerSalt = bytes32(uint256(0xdead));
        _openCorePositionDir(attackerSalt, true); // hostile, opposite direction

        uint256 nextTokenId = marginPositionManager.nextId();
        vm.expectRevert(IMarginCore.PositionTransferRejected.selector);
        marginCore.transferPosition(key, attackerSalt, address(marginPositionManager), bytes32(nextTokenId));
    }

    /// #1: transferring into any non-accepting contract's namespace reverts.
    function testTransferPosition_Fail_ContractRejects() public {
        bytes32 saltA = bytes32(uint256(1));
        _openCorePosition(saltA);
        // pairPositionManager is a contract that does not implement the receiver hook
        vm.expectRevert(IMarginCore.PositionTransferRejected.selector);
        marginCore.transferPosition(key, saltA, address(pairPositionManager), saltA);
    }

    /// #5: adding to an existing position with the opposite direction reverts on the core.
    function testMarginDirectionMismatch() public {
        bytes32 salt = bytes32(uint256(0xabc));
        _openCorePositionDir(salt, false);

        token1.mint(address(this), MARGIN_AMOUNT); // pre-mint so the revert is on the unlock
        IMarginCore.MarginParams memory params = IMarginCore.MarginParams({
            salt: salt,
            marginForOne: true,
            leverage: 2,
            marginAmount: MARGIN_AMOUNT,
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this)
        });
        bytes memory payload = abi.encode(this.margin_callback.selector, abi.encode(key, params));
        vm.expectRevert(IMarginCore.DirectionMismatch.selector);
        vault.unlock(payload);
    }

    /// #4: refinance burns the NFT so no live token backs the emptied position.
    function testRefinance_BurnsNFT() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);

        assertEq(marginPositionManager.ownerOf(tokenId), address(this));
        _refinance(tokenId, quoteId);

        vm.expectRevert();
        marginPositionManager.ownerOf(tokenId);
    }

    /// Review-2 #2: an attacker cannot pre-occupy the debt market's destination slot to grief a
    /// refinance — the receive hook rejects any transfer it did not arm via prepareRefinance.
    function testDebtMarket_RejectsUnarmedTransfer() public {
        bytes32 attackerSalt = bytes32(uint256(0xbeef));
        _openCorePosition(attackerSalt);
        // The next loan's destination slot the debt market would arm:
        bytes32 targetSalt = keccak256(abi.encodePacked(address(debtMarket), debtMarket.nextLoanId()));

        vm.expectRevert(IMarginCore.PositionTransferRejected.selector);
        marginCore.transferPosition(key, attackerSalt, address(debtMarket), targetSalt);

        // The legitimate refinance still succeeds (arms its own slot in-tx).
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);
        uint256 loanId = _refinance(tokenId, quoteId);
        (,,,, uint128 faceValue,,) = _loan(loanId);
        assertGt(faceValue, 0);
    }

    /// Review-2 #1: during a zero-price window a default redeem must not pay out uncapped
    /// collateral (which would drain the borrower's excess); it reverts until a price returns.
    function testRedeem_BlockedWhenPriceUnavailable() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000);
        uint256 quoteId = _postQuote(key.toId(), false);
        uint256 loanId = _refinance(tokenId, quoteId);
        (,,,, uint128 faceValue,,) = _loan(loanId);

        skip(DURATION + 1); // default

        // Force truncated reserves to read zero via a mocked pool state call.
        _mockZeroTruncatedReserves(key.toId());
        vm.prank(underwriter);
        vm.expectRevert(LikwidDebtMarket.SettlementPriceUnavailable.selector);
        debtMarket.redeem(loanId, faceValue);
        vm.clearMockedCalls();

        // Once a price is available again the redeem settles normally (capped).
        vm.prank(underwriter);
        uint256 payout = debtMarket.redeem(loanId, faceValue);
        assertGt(payout, 0);
    }

    /// #3: a stale liquidation with an expired deadline reverts instead of executing.
    function testLiquidate_ExpiredDeadline() public {
        uint256 tokenId = _createPosition(key, false);
        skip(1000); // advance so deadline=1 is in the past
        PoolKey memory k = _poolKeyOf(tokenId); // resolve args before expectRevert
        address wrapper = address(marginPositionManager);
        bytes32 salt = bytes32(tokenId);

        vm.expectRevert(bytes("EXPIRED"));
        marginCore.liquidateCall(k, wrapper, salt, address(this), 1);
        vm.expectRevert(bytes("EXPIRED"));
        marginCore.liquidateBurn(k, wrapper, salt, address(this), 1);
    }

    /// @dev Forces CurrentStateLibrary.getState to see zero pair+truncated reserves for a pool by
    /// mocking the batched extsload it reads (indices 6 = pair, 7 = truncated). With both zero,
    /// PriceMath leaves truncated at zero (no pair to back-fill from).
    function _mockZeroTruncatedReserves(PoolId poolId) internal {
        bytes32 poolStateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(10))));
        bytes32 startSlot = bytes32(uint256(poolStateSlot) + 1);
        bytes32[] memory data = IVault(address(vault)).extsload(startSlot, 11);
        data[6] = bytes32(0); // pairReserves
        data[7] = bytes32(0); // truncatedReserves
        vm.mockCall(
            address(vault),
            abi.encodeWithSignature("extsload(bytes32,uint256)", startSlot, uint256(11)),
            abi.encode(data)
        );
    }

    function _poolKeyOf(uint256 tokenId) internal view returns (PoolKey memory k) {
        (k.currency0, k.currency1, k.fee, k.marginFee) =
            marginPositionManager.poolKeys(marginPositionManager.poolIds(tokenId));
    }
}

contract MockFundingSource is ILikwidDebtFundingCallback {
    LikwidDebtMarket immutable market;
    bool revertOnFunding;
    bool reenter;
    uint256 maxDelivery = type(uint256).max;
    bool public reentryBlocked;

    constructor(LikwidDebtMarket _market) {
        market = _market;
    }

    function setRevertOnFunding(bool v) external {
        revertOnFunding = v;
    }

    function setMaxDelivery(uint256 v) external {
        maxDelivery = v;
    }

    function setReenter(bool v) external {
        reenter = v;
    }

    function likwidDebtMarketFunding(uint256, address fundingToken, uint256 amount) external {
        if (revertOnFunding) revert("no funds");
        if (reenter) {
            try market.repayLoan(1) {
                reentryBlocked = false;
            } catch (bytes memory reason) {
                reentryBlocked = bytes4(reason) == LikwidDebtMarket.Reentrancy.selector;
            }
        }
        uint256 pay = amount > maxDelivery ? maxDelivery : amount;
        uint256 balance = MockERC20(fundingToken).balanceOf(address(this));
        if (pay > balance) pay = balance;
        MockERC20(fundingToken).transfer(msg.sender, pay);
    }
}
