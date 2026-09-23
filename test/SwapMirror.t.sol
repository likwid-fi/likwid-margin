// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LikwidVault} from "../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../src/LikwidPairPosition.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IPairPositionManager} from "../src/interfaces/IPairPositionManager.sol";
import {IBasePositionManager} from "../src/interfaces/IBasePositionManager.sol";
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../src/types/Currency.sol";
import {Reserves, ReservesLibrary} from "../src/types/Reserves.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {MirrorShares} from "../src/libraries/MirrorShares.sol";
import {FixedPoint96} from "../src/libraries/FixedPoint96.sol";
import {LikwidHelper} from "./utils/LikwidHelper.sol";

contract SwapMirrorTest is Test {
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidPairPosition pairPositionManager;
    LikwidMarginPosition marginPositionManager;
    LikwidHelper helper;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolKey keyNative;
    PoolId id;

    address alice = makeAddr("alice");

    receive() external payable {}

    function setUp() public {
        vault = new LikwidVault(address(this));
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);
        vault.setMarginController(address(marginPositionManager));

        MockERC20 tokenA = new MockERC20("TokenA", "TKNA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKNB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            marginFee: 3000
        });
        vault.initialize(key);
        id = key.toId();
        keyNative = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            marginFee: 3000
        });
        vault.initialize(keyNative);

        token0.mint(address(this), 10e18);
        token1.mint(address(this), 40e18);
        pairPositionManager.addLiquidity(key, address(this), 10e18, 20e18, 0, 0, block.timestamp);
        pairPositionManager.addLiquidity{value: 10e18}(keyNative, address(this), 10e18, 20e18, 0, 0, block.timestamp);
    }

    // ==================== helpers ====================

    function _mirrorIn(bool zeroForOne, uint256 amountIn, uint256 realOutMax)
        internal
        returns (uint256 realOut, uint256 mirrorOut, uint256 shares)
    {
        (zeroForOne ? token0 : token1).mint(address(this), amountIn);
        (,, realOut, mirrorOut, shares) = pairPositionManager.exactInputMirror(
            IPairPositionManager.SwapMirrorInputParams({
                poolId: id,
                zeroForOne: zeroForOne,
                to: address(this),
                amountIn: amountIn,
                amountOutMin: 0,
                realOutMax: realOutMax,
                deadline: block.timestamp
            })
        );
    }

    function _plainIn(bool zeroForOne, uint256 amountIn) internal returns (uint256 amountOut) {
        (zeroForOne ? token0 : token1).mint(address(this), amountIn);
        (,, amountOut) = pairPositionManager.exactInput(
            IPairPositionManager.SwapInputParams({
                poolId: id,
                zeroForOne: zeroForOne,
                to: address(this),
                amountIn: amountIn,
                amountOutMin: 0,
                deadline: block.timestamp
            })
        );
    }

    /// What a plain swap of the same size would pay out
    function _quote(bool zeroForOne, uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 snapshot = vm.snapshotState();
        amountOut = _plainIn(zeroForOne, amountIn);
        vm.revertToState(snapshot);
    }

    function _openPosition(bool marginForOne, uint128 marginAmount) internal returns (uint256 tokenId) {
        (marginForOne ? token1 : token0).mint(address(this), marginAmount);
        (tokenId,,) = marginPositionManager.addMargin(
            key,
            IMarginPositionManager.CreateParams({
                marginForOne: marginForOne,
                leverage: 2,
                marginAmount: marginAmount,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _redeem(bool redeemForOne, uint256 shares) internal returns (uint256) {
        return pairPositionManager.redeemMirror(id, redeemForOne, shares, address(this), 0, block.timestamp);
    }

    function _reserves(function(IVault, PoolId) view returns (Reserves) getter)
        internal
        view
        returns (uint128 r0, uint128 r1)
    {
        (r0, r1) = getter(vault, id).reserves();
    }

    function _shareId(bool forOne) internal view returns (uint256) {
        return MirrorShares.toId(id, forOne);
    }

    // ==================== swapMirror ====================

    function testPureMirror_ExactInput() public {
        (uint128 real0Before, uint128 real1Before) = _reserves(StateLibrary.getRealReserves);
        (uint128 pair0Before, uint128 pair1Before) = _reserves(StateLibrary.getPairReserves);
        uint256 token1Before = token1.balanceOf(address(this));

        (uint256 realOut, uint256 mirrorOut, uint256 shares) = _mirrorIn(true, 1e18, 0);

        assertEq(realOut, 0);
        assertGt(mirrorOut, 0);
        // a fresh pool's deposit cumulative is Q96, so a share is worth one unit
        assertEq(shares, mirrorOut);
        assertEq(vault.balanceOf(address(this), _shareId(true)), shares);
        assertEq(token1.balanceOf(address(this)), token1Before);

        (uint128 real0, uint128 real1) = _reserves(StateLibrary.getRealReserves);
        (uint128 pair0, uint128 pair1) = _reserves(StateLibrary.getPairReserves);
        (, uint128 lend1) = _reserves(StateLibrary.getLendReserves);
        // the input side moves exactly as in a plain swap (protocol fee leaves both)
        assertEq(real0 - real0Before, pair0 - pair0Before);
        assertGt(real0, real0Before);
        assertEq(real1, real1Before);
        assertEq(pair1, pair1Before - mirrorOut);
        assertEq(lend1, mirrorOut);
    }

    function testMirrorPricedLikePlainSwap() public {
        uint256 snapshot = vm.snapshotState();
        uint256 plainOut = _plainIn(true, 1e18);
        (uint128 pair0Plain, uint128 pair1Plain) = _reserves(StateLibrary.getPairReserves);
        vm.revertToState(snapshot);

        (uint256 realOut, uint256 mirrorOut,) = _mirrorIn(true, 1e18, 0.4e18);
        (uint128 pair0, uint128 pair1) = _reserves(StateLibrary.getPairReserves);

        assertEq(realOut, 0.4e18);
        assertEq(realOut + mirrorOut, plainOut);
        assertEq(pair0, pair0Plain);
        assertEq(pair1, pair1Plain);
    }

    function testMixed_RealPartPaidOut() public {
        uint256 token1Before = token1.balanceOf(address(this));
        uint128 real1Before = _real1();

        (uint256 realOut, uint256 mirrorOut, uint256 shares) = _mirrorIn(true, 1e18, 0.5e18);

        assertEq(realOut, 0.5e18);
        assertGt(mirrorOut, 0);
        assertEq(token1.balanceOf(address(this)), token1Before + realOut);
        assertEq(_real1(), real1Before - realOut);
        assertEq(vault.balanceOf(address(this), _shareId(true)), shares);
    }

    function testRealOutMaxAboveOutput_IsPlainSwap() public {
        vm.recordLogs();
        (uint256 realOut, uint256 mirrorOut, uint256 shares) = _mirrorIn(true, 1e18, type(uint256).max);
        assertGt(realOut, 0);
        assertEq(mirrorOut, 0);
        assertEq(shares, 0);
        (, uint128 lend1) = _reserves(StateLibrary.getLendReserves);
        assertEq(lend1, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != IVault.MirrorSwap.selector);
        }
    }

    function testPureMirror_ExactOutput() public {
        uint256 snapshot = vm.snapshotState();
        token1.mint(address(this), 10e18);
        (,, uint256 plainIn) = pairPositionManager.exactOutput(
            IPairPositionManager.SwapOutputParams({
                poolId: id,
                zeroForOne: false,
                to: address(this),
                amountInMax: 0,
                amountOut: 1e18,
                deadline: block.timestamp
            })
        );
        vm.revertToState(snapshot);

        token1.mint(address(this), 10e18);
        uint256 token0Before = token0.balanceOf(address(this));
        (,, uint256 amountIn, uint256 realOut, uint256 mirrorOut, uint256 shares) = pairPositionManager.exactOutputMirror(
            IPairPositionManager.SwapMirrorOutputParams({
                poolId: id,
                zeroForOne: false,
                to: address(this),
                amountInMax: 0,
                amountOut: 1e18,
                realOutMax: 0,
                deadline: block.timestamp
            })
        );

        assertEq(amountIn, plainIn);
        assertEq(realOut, 0);
        assertEq(mirrorOut, 1e18);
        assertEq(token0.balanceOf(address(this)), token0Before);
        assertEq(vault.balanceOf(address(this), _shareId(false)), shares);
        (uint128 lend0,) = _reserves(StateLibrary.getLendReserves);
        assertEq(lend0, 1e18);
    }

    function testSharesMintedToRecipient() public {
        token0.mint(address(this), 1e18);
        (,,, uint256 mirrorOut, uint256 shares) = pairPositionManager.exactInputMirror(
            IPairPositionManager.SwapMirrorInputParams({
                poolId: id,
                zeroForOne: true,
                to: alice,
                amountIn: 1e18,
                amountOutMin: 0,
                realOutMax: 0,
                deadline: block.timestamp
            })
        );
        assertGt(mirrorOut, 0);
        assertEq(vault.balanceOf(alice, _shareId(true)), shares);
        assertEq(vault.balanceOf(address(this), _shareId(true)), 0);
    }

    function testEmitMirrorSwap() public {
        uint256 expectedOut = _quote(true, 1e18);
        token0.mint(address(this), 1e18);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IVault.MirrorSwap(
            id, address(pairPositionManager), address(this), true, expectedOut, expectedOut, FixedPoint96.Q96
        );
        pairPositionManager.exactInputMirror(
            IPairPositionManager.SwapMirrorInputParams({
                poolId: id,
                zeroForOne: true,
                to: address(this),
                amountIn: 1e18,
                amountOutMin: 0,
                realOutMax: 0,
                deadline: block.timestamp
            })
        );
    }

    function testRevertMirror_SlippageOnWholeOutput() public {
        uint256 expectedOut = _quote(true, 1e18);
        token0.mint(address(this), 2e18);
        IPairPositionManager.SwapMirrorInputParams memory params = IPairPositionManager.SwapMirrorInputParams({
            poolId: id,
            zeroForOne: true,
            to: address(this),
            amountIn: 1e18,
            amountOutMin: expectedOut + 1,
            realOutMax: 0.1e18,
            deadline: block.timestamp
        });
        vm.expectRevert(IBasePositionManager.PriceSlippageTooHigh.selector);
        pairPositionManager.exactInputMirror(params);

        // real and mirror together meet the minimum even though the real part alone does not
        params.amountOutMin = expectedOut;
        pairPositionManager.exactInputMirror(params);
    }

    function testRevertMirror_ZeroAmount() public {
        vm.expectRevert(IVault.AmountCannotBeZero.selector);
        pairPositionManager.exactInputMirror(
            IPairPositionManager.SwapMirrorInputParams({
                poolId: id,
                zeroForOne: true,
                to: address(this),
                amountIn: 0,
                amountOutMin: 0,
                realOutMax: 0,
                deadline: block.timestamp
            })
        );
    }

    function testRevertMirror_WhenLocked() public {
        vm.expectRevert(IVault.VaultLocked.selector);
        vault.swapMirror(
            key, IVault.SwapMirrorParams({zeroForOne: true, amountSpecified: -1e18, realOutMax: 0, recipient: alice})
        );
    }

    // ==================== redeem ====================

    function testRedeem_All() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        uint256 token1Before = token1.balanceOf(address(this));
        vault.setOperator(address(pairPositionManager), true);

        uint256 amount = _redeem(true, type(uint256).max);

        assertEq(amount, shares);
        assertEq(token1.balanceOf(address(this)), token1Before + amount);
        assertEq(vault.balanceOf(address(this), _shareId(true)), 0);
        (, uint128 lend1) = _reserves(StateLibrary.getLendReserves);
        assertEq(lend1, 0);
    }

    function testRedeem_Partial() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vault.setOperator(address(pairPositionManager), true);

        uint256 amount = _redeem(true, shares / 3);

        assertEq(amount, shares / 3);
        assertEq(vault.balanceOf(address(this), _shareId(true)), shares - shares / 3);
    }

    /// Mirror swap then an immediate redeem nets out to a plain swap.
    function testMirrorThenRedeem_EqualsPlainSwap() public {
        uint256 snapshot = vm.snapshotState();
        uint256 plainOut = _plainIn(true, 1e18);
        (uint128 real0Plain, uint128 real1Plain) = _reserves(StateLibrary.getRealReserves);
        (uint128 pair0Plain, uint128 pair1Plain) = _reserves(StateLibrary.getPairReserves);
        vm.revertToState(snapshot);

        _mirrorIn(true, 1e18, 0);
        vault.setOperator(address(pairPositionManager), true);
        uint256 amount = _redeem(true, type(uint256).max);

        assertEq(amount, plainOut);
        (uint128 real0, uint128 real1) = _reserves(StateLibrary.getRealReserves);
        (uint128 pair0, uint128 pair1) = _reserves(StateLibrary.getPairReserves);
        assertEq(real0, real0Plain);
        assertEq(real1, real1Plain);
        assertEq(pair0, pair0Plain);
        assertEq(pair1, pair1Plain);
    }

    function testRedeem_AccruesInterest() public {
        // a leveraged position borrowing token1 pays interest into the token1 side
        token0.mint(address(this), 0.2e18);
        marginPositionManager.addMargin(
            key,
            IMarginPositionManager.CreateParams({
                marginForOne: false,
                leverage: 2,
                marginAmount: 0.2e18,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        (, uint256 mirrorOut, uint256 shares) = _mirrorIn(true, 1e18, 0);
        skip(30 days);

        uint256 worth = helper.getMirrorShareAmount(id, true, shares);
        assertGt(worth, mirrorOut);

        vault.setOperator(address(pairPositionManager), true);
        uint256 amount = _redeem(true, shares);
        assertEq(amount, worth);
    }

    /// Redeeming waits on real reserves: with token1 lent out and drained by swaps it reverts,
    /// and works again once the borrower repays.
    /// real1 - lend1 == pair1 - mirror1, and every pure mirror swap lowers pair1 by what it credits to lend1.
    /// Borrow token1, then pure-mirror sell token0 until the shares are worth more than the real token1 left.
    function _shortOfRealToken1() internal returns (uint256 tokenId, uint256 shares) {
        tokenId = _openPosition(false, 0.4e18);
        for (uint256 i = 0; i < 100 && _real1() >= helper.getMirrorShareAmount(id, true, shares); i++) {
            (,, uint256 minted) = _mirrorIn(true, 2e18, 0);
            shares += minted;
            skip(1 hours);
        }
        assertLt(_real1(), helper.getMirrorShareAmount(id, true, shares));
    }

    function testRedeem_WaitsForRealReserves() public {
        (uint256 tokenId, uint256 shares) = _shortOfRealToken1();

        vault.setOperator(address(pairPositionManager), true);
        vm.expectRevert(ReservesLibrary.NotEnoughReserves.selector);
        _redeem(true, shares);

        // repaying brings real token1 back
        token1.mint(address(this), 10e18);
        marginPositionManager.repay(tokenId, type(uint256).max, block.timestamp);
        uint256 worth = helper.getMirrorShareAmount(id, true, shares);
        assertEq(_redeem(true, shares), worth);
    }

    /// With the outstanding shares worth more than the real token1 left, a pure mirror swap still goes through
    /// and leaves real token1 untouched.
    function testShortOfReal_PureMirrorStillWorks() public {
        (, uint256 sharesBefore) = _shortOfRealToken1();
        uint256 real1 = _real1();

        (uint256 realOut, uint256 mirrorOut, uint256 shares) = _mirrorIn(true, 1e18, 0);

        assertEq(realOut, 0);
        assertGt(mirrorOut, 0);
        assertEq(_real1(), real1);
        assertEq(vault.balanceOf(address(this), _shareId(true)), sharesBefore + shares);
    }

    function testRedeem_TransferredShares() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vault.transfer(alice, _shareId(true), shares);

        vm.startPrank(alice);
        vault.setOperator(address(pairPositionManager), true);
        uint256 amount = pairPositionManager.redeemMirror(id, true, type(uint256).max, alice, 0, block.timestamp);
        vm.stopPrank();

        assertEq(amount, shares);
        assertEq(token1.balanceOf(alice), amount);
    }

    function testRevertRedeem_WithoutApproval() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vm.expectRevert();
        _redeem(true, shares);
    }

    function testRevertRedeem_OthersShares() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vault.setOperator(address(pairPositionManager), true);
        // alice has no shares; the manager only ever burns from its caller
        vm.prank(alice);
        vm.expectRevert();
        pairPositionManager.redeemMirror(id, true, shares, alice, 0, block.timestamp);
    }

    function testRevertRedeem_ZeroShares() public {
        vault.setOperator(address(pairPositionManager), true);
        vm.expectRevert(IVault.AmountCannotBeZero.selector);
        _redeem(true, 0);
    }

    function testRevertRedeem_Slippage() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vault.setOperator(address(pairPositionManager), true);
        vm.expectRevert(IBasePositionManager.PriceSlippageTooHigh.selector);
        pairPositionManager.redeemMirror(id, true, shares, address(this), shares + 1, block.timestamp);
    }

    function testRedeem_Native() public {
        // selling token1 for native currency0, all of it as shares
        token1.mint(address(this), 2e18);
        (,,, uint256 mirrorOut, uint256 shares) = pairPositionManager.exactInputMirror(
            IPairPositionManager.SwapMirrorInputParams({
                poolId: keyNative.toId(),
                zeroForOne: false,
                to: address(this),
                amountIn: 2e18,
                amountOutMin: 0,
                realOutMax: 0,
                deadline: block.timestamp
            })
        );
        assertGt(mirrorOut, 0);

        vault.setOperator(address(pairPositionManager), true);
        uint256 balanceBefore = address(this).balance;
        uint256 amount =
            pairPositionManager.redeemMirror(keyNative.toId(), false, shares, address(this), 0, block.timestamp);
        assertEq(amount, mirrorOut);
        assertEq(address(this).balance, balanceBefore + amount);
    }

    // ==================== share math ====================

    /// Shares minted after interest has accrued are fewer than the amount, and redeem back to it (rounded down).
    function testShares_MintedAfterInterest_RedeemAtPar() public {
        _openPosition(false, 0.2e18); // borrows token1, so the token1 deposit cumulative grows
        _mirrorIn(true, 0.5e18, 0); // someone has to hold token1 lend for the cumulative to move
        skip(30 days);

        (, uint256 mirrorOut, uint256 shares) = _mirrorIn(true, 1e18, 0);
        (, uint256 cum1) = _depositCumulatives();
        assertGt(cum1, FixedPoint96.Q96);
        assertLt(shares, mirrorOut);

        vault.setOperator(address(pairPositionManager), true);
        uint256 amount = _redeem(true, shares);
        assertLe(amount, mirrorOut);
        assertApproxEqAbs(amount, mirrorOut, 2);
    }

    /// Margin collateral and mirror shares share lendReserves and one deposit cumulative: every claim on it
    /// can be taken out in full, in any order, and at most rounding dust is left.
    function testLendReserves_CoverCollateralAndShares() public {
        _openPosition(false, 0.2e18); // borrows token1: interest on the token1 side
        uint256 collateralId = _openPosition(true, 0.2e18); // token1 collateral in lend1
        (,, uint256 sharesA) = _mirrorIn(true, 1e18, 0);
        skip(10 days);
        (,, uint256 sharesB) = _mirrorIn(true, 0.5e18, 0);
        vm.prank(address(this));
        vault.transfer(alice, _shareId(true), sharesB);
        skip(20 days);

        vault.setOperator(address(pairPositionManager), true);
        assertGt(_redeem(true, sharesA), 0);
        marginPositionManager.close(collateralId, 1_000_000, 0, block.timestamp);
        vm.startPrank(alice);
        vault.setOperator(address(pairPositionManager), true);
        assertGt(pairPositionManager.redeemMirror(id, true, sharesB, alice, 0, block.timestamp), 0);
        vm.stopPrank();

        (, uint128 lend1) = _reserves(StateLibrary.getLendReserves);
        assertLe(lend1, 10);
    }

    /// Shares stay whole when a position whose collateral sits next to them in lend1 is liquidated.
    function testRedeem_AfterLiquidationInSameCurrency() public {
        uint256 tokenId = _openPosition(true, 0.2e18); // token1 collateral, borrows token0
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        uint256 worth = helper.getMirrorShareAmount(id, true, shares);

        // dump token1 until the position can be liquidated
        for (uint256 i = 0; i < 50 && !helper.checkMarginPositionLiquidate(tokenId); i++) {
            _plainIn(false, 2e18);
            skip(1 hours);
        }
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));
        marginPositionManager.liquidateBurn(tokenId, block.timestamp);

        vault.setOperator(address(pairPositionManager), true);
        assertGe(_redeem(true, shares), worth);
    }

    function testFuzz_SplitMatchesPlainSwap(bool zeroForOne, uint256 amountIn, uint256 realOutMax) public {
        amountIn = bound(amountIn, 1e9, 5e18);
        uint256 plainOut = _quote(zeroForOne, amountIn);
        realOutMax = bound(realOutMax, 0, plainOut * 2);
        (uint128 pair0Plain, uint128 pair1Plain) = _pairAfterPlain(zeroForOne, amountIn);

        (uint256 realOut, uint256 mirrorOut, uint256 shares) = _mirrorIn(zeroForOne, amountIn, realOutMax);

        assertEq(realOut, realOutMax < plainOut ? realOutMax : plainOut);
        assertEq(realOut + mirrorOut, plainOut);
        assertEq(shares, mirrorOut);
        (uint128 pair0, uint128 pair1) = _reserves(StateLibrary.getPairReserves);
        assertEq(pair0, pair0Plain);
        assertEq(pair1, pair1Plain);
        (uint128 lend0, uint128 lend1) = _reserves(StateLibrary.getLendReserves);
        assertEq(zeroForOne ? lend1 : lend0, mirrorOut);
    }

    // ==================== fees and events ====================

    function testProtocolFee_SameAsPlainSwap() public {
        assertGt(vault.defaultProtocolFee(), 0);
        Currency c0 = key.currency0;
        uint256 snapshot = vm.snapshotState();
        _plainIn(true, 1e18);
        uint256 plainFee = vault.protocolFeesAccrued(c0);
        vm.revertToState(snapshot);

        _mirrorIn(true, 1e18, 0);
        assertGt(plainFee, 0);
        assertEq(vault.protocolFeesAccrued(c0), plainFee);
    }

    /// The Swap event reports the whole trade, mirror part included.
    function testEmitSwap_WholeTrade() public {
        uint256 out = _quote(true, 1e18);
        token0.mint(address(this), 1e18);
        vm.recordLogs();
        pairPositionManager.exactInputMirror(
            IPairPositionManager.SwapMirrorInputParams({
                poolId: id,
                zeroForOne: true,
                to: address(this),
                amountIn: 1e18,
                amountOutMin: 0,
                realOutMax: 0.3e18,
                deadline: block.timestamp
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == IVault.Swap.selector) {
                (int128 amount0, int128 amount1,) = abi.decode(logs[i].data, (int128, int128, uint24));
                assertEq(amount0, -1e18);
                assertEq(uint256(int256(amount1)), out);
                found = true;
            }
        }
        assertTrue(found);
    }

    function testEmitRedeem() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vault.setOperator(address(pairPositionManager), true);
        vm.expectEmit(true, true, true, true, address(vault));
        emit IVault.Redeem(id, address(pairPositionManager), address(this), true, shares, shares, FixedPoint96.Q96);
        _redeem(true, shares);
    }

    // ==================== exact output ====================

    function testExactOutputMirror_Mixed() public {
        token0.mint(address(this), 10e18);
        uint256 token1Before = token1.balanceOf(address(this));
        (,,, uint256 realOut, uint256 mirrorOut, uint256 shares) = pairPositionManager.exactOutputMirror(
            IPairPositionManager.SwapMirrorOutputParams({
                poolId: id,
                zeroForOne: true,
                to: address(this),
                amountInMax: 0,
                amountOut: 1e18,
                realOutMax: 0.25e18,
                deadline: block.timestamp
            })
        );
        assertEq(realOut, 0.25e18);
        assertEq(mirrorOut, 0.75e18);
        assertEq(shares, 0.75e18);
        assertEq(token1.balanceOf(address(this)), token1Before + 0.25e18);
    }

    function testRevertExactOutputMirror_AmountInMax() public {
        token0.mint(address(this), 10e18);
        IPairPositionManager.SwapMirrorOutputParams memory params = IPairPositionManager.SwapMirrorOutputParams({
            poolId: id,
            zeroForOne: true,
            to: address(this),
            amountInMax: 0.1e18,
            amountOut: 1e18,
            realOutMax: 0,
            deadline: block.timestamp
        });
        vm.expectRevert(IBasePositionManager.PriceSlippageTooHigh.selector);
        pairPositionManager.exactOutputMirror(params);
    }

    // ==================== redeem authorisation ====================

    /// An allowance works as well as an operator, and is used up.
    function testRedeem_WithAllowance() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vault.approve(address(pairPositionManager), _shareId(true), shares);
        _redeem(true, shares);
        assertEq(vault.allowance(address(this), address(pairPositionManager), _shareId(true)), 0);
    }

    function testRevertRedeem_MoreThanBalance() public {
        (,, uint256 shares) = _mirrorIn(true, 1e18, 0);
        vault.setOperator(address(pairPositionManager), true);
        vm.expectRevert();
        _redeem(true, shares + 1);
    }

    // ==================== share ids ====================

    function testShareIdsDisjointFromCurrencyClaims() public view {
        uint256 id0 = _shareId(false);
        uint256 id1 = _shareId(true);
        assertGt(id0, type(uint160).max);
        assertGt(id1, type(uint160).max);
        assertTrue(id0 != id1);
        assertTrue(MirrorShares.toId(keyNative.toId(), true) != id1);
        assertEq(helper.getMirrorShareId(id, true), id1);
    }

    // ==================== internal ====================

    function _depositCumulatives() internal view returns (uint256 cum0, uint256 cum1) {
        (,, cum0, cum1) = StateLibrary.getBorrowDepositCumulative(vault, id);
    }

    function _pairAfterPlain(bool zeroForOne, uint256 amountIn) internal returns (uint128 pair0, uint128 pair1) {
        uint256 snapshot = vm.snapshotState();
        _plainIn(zeroForOne, amountIn);
        (pair0, pair1) = _reserves(StateLibrary.getPairReserves);
        vm.revertToState(snapshot);
    }

    function _real1() internal view returns (uint128 real1) {
        (, real1) = StateLibrary.getRealReserves(vault, id).reserves();
    }
}
