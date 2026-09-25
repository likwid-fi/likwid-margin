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
import {IMarginPositionManager} from "../src/interfaces/IMarginPositionManager.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../src/types/PoolId.sol";
import {Currency} from "../src/types/Currency.sol";
import {Reserves, ReservesLibrary} from "../src/types/Reserves.sol";
import {InsuranceFunds} from "../src/types/InsuranceFunds.sol";
import {StateLibrary} from "../src/libraries/StateLibrary.sol";
import {Math} from "../src/libraries/Math.sol";
import {LikwidHelper} from "./utils/LikwidHelper.sol";

/// A leveraged position (token0 collateral, token1 debt) goes under when token0 is dumped; liquidateCall books the
/// lost token1 as a negative currency1 insurance fund. A currency0 surplus then buys it back from the pair.
contract InsuranceFundsRebalanceTest is Test {
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidPairPosition pairPositionManager;
    LikwidMarginPosition marginPositionManager;
    LikwidHelper helper;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;
    uint256 lpTokenId;
    uint128 lpLiquidity;

    function setUp() public {
        vault = new LikwidVault(address(this));
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);
        vault.setMarginController(address(marginPositionManager));
        // no staged lock, so the LP can try to leave in one go
        vault.setMarginState(vault.marginState().setStageDuration(0));

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

        token0.mint(address(this), 10e18);
        token1.mint(address(this), 20e18);
        (lpTokenId, lpLiquidity) =
            pairPositionManager.addLiquidity(key, address(this), 10e18, 20e18, 0, 0, block.timestamp);
    }

    // ==================== helpers ====================

    function _donate(uint256 amount0, uint256 amount1) internal {
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        pairPositionManager.donate(id, amount0, amount1, block.timestamp);
    }

    /// Opens a 4x position on token0, dumps token0 and liquidates it at a loss.
    /// Returns the lost token1 and the logs of the liquidation.
    function _badDebt() internal returns (uint256 lostAmount, Vm.Log[] memory logs) {
        token0.mint(address(this), 0.1e18);
        (uint256 tokenId,,) = marginPositionManager.addMargin(
            key,
            IMarginPositionManager.CreateParams({
                marginForOne: false,
                leverage: 4,
                marginAmount: 0.1e18,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        skip(1000);
        token0.mint(address(this), 5e18);
        pairPositionManager.exactInput(
            IPairPositionManager.SwapInputParams({
                poolId: id,
                zeroForOne: true,
                to: address(this),
                amountIn: 5e18,
                amountOutMin: 0,
                deadline: block.timestamp
            })
        );
        skip(1000);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));

        token1.mint(address(this), 10e18);
        vm.recordLogs();
        marginPositionManager.liquidateCall(tokenId, block.timestamp);
        logs = vm.getRecordedLogs();

        bytes32 liquidateCall = IMarginPositionManager.LiquidateCall.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == liquidateCall) {
                (,,,,,,,,, lostAmount,) = abi.decode(
                    logs[i].data,
                    (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
                );
            }
        }
        assertGt(lostAmount, 0, "liquidation should lose token1");
    }

    function _rebalanceEvent(Vm.Log[] memory logs)
        internal
        view
        returns (bool found, bool zeroForOne, uint256 amountIn, uint256 amountOut)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == IVault.InsuranceFundsSwap.selector) {
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                (zeroForOne, amountIn, amountOut) = abi.decode(logs[i].data, (bool, uint256, uint256));
                found = true;
            }
        }
    }

    function _funds() internal view returns (int128 fund0, int128 fund1) {
        (fund0, fund1) = StateLibrary.getInsuranceFunds(vault, id).unpack();
    }

    /// real + mirror == pair + lend + funds, per currency
    function _assertConsistent() internal view {
        (uint128 real0, uint128 real1) = StateLibrary.getRealReserves(vault, id).reserves();
        (uint128 mirror0, uint128 mirror1) = StateLibrary.getMirrorReserves(vault, id).reserves();
        (uint128 pair0, uint128 pair1) = StateLibrary.getPairReserves(vault, id).reserves();
        (uint128 lend0, uint128 lend1) = StateLibrary.getLendReserves(vault, id).reserves();
        (int128 fund0, int128 fund1) = _funds();
        assertEq(int256(uint256(real0) + mirror0), int256(uint256(pair0) + lend0) + fund0, "currency0");
        assertEq(int256(uint256(real1) + mirror1), int256(uint256(pair1) + lend1) + fund1, "currency1");
    }

    function _removeAllLiquidity() internal {
        pairPositionManager.removeLiquidity(lpTokenId, lpLiquidity, 0, 0, block.timestamp);
    }

    // ==================== tests ====================

    /// Without a surplus on the other side the shortfall stays, and so does the hole: the LP cannot leave in full.
    function testNoSurplus_ShortfallStays() public {
        (uint256 lost, Vm.Log[] memory logs) = _badDebt();
        (bool found,,,) = _rebalanceEvent(logs);
        assertFalse(found);

        (int128 fund0, int128 fund1) = _funds();
        assertEq(fund0, 0);
        assertApproxEqAbs(fund1, -int128(int256(lost)), 1); // the event's lostAmount can be 1 wei off
        _assertConsistent();

        vm.expectRevert(ReservesLibrary.NotEnoughReserves.selector);
        _removeAllLiquidity();
    }

    /// A currency0 surplus buys the whole shortfall from the pair on its curve, in the liquidation itself.
    function testSurplus_FillsShortfall() public {
        _donate(1e18, 0);
        (uint256 lost, Vm.Log[] memory logs) = _badDebt();

        (bool found, bool zeroForOne, uint256 amountIn, uint256 amountOut) = _rebalanceEvent(logs);
        assertTrue(found);
        assertTrue(zeroForOne);
        assertApproxEqAbs(amountOut, lost, 1);

        (int128 fund0, int128 fund1) = _funds();
        assertEq(fund1, 0);
        assertEq(fund0, int128(int256(1e18 - amountIn)));

        // priced on the pair's curve, rounded up for the pair, so k does not fall
        (uint128 pair0, uint128 pair1) = StateLibrary.getPairReserves(vault, id).reserves();
        uint256 pair0Before = pair0 - amountIn;
        uint256 pair1Before = pair1 + amountOut;
        assertEq(amountIn, Math.mulDivRoundingUp(pair0Before, amountOut, pair1Before - amountOut));
        assertGe(uint256(pair0) * pair1, pair0Before * pair1Before);
        _assertConsistent();
    }

    /// With the hole filled, the LP can leave in full (the same removal reverts without the fill, see above).
    function testSurplus_LPExitsInFull() public {
        _donate(1e18, 0);
        _badDebt();
        _removeAllLiquidity();
        assertEq(pairPositionManager.getPositionState(lpTokenId).liquidity, 0);
        _assertConsistent();
    }

    /// Mirror shares on the short currency and the LP both get out in full once the hole is filled.
    function testSurplus_SharesAndLPExitInFull() public {
        _donate(1e18, 0);
        token0.mint(address(this), 0.5e18);
        (,,,, uint256 shares) = pairPositionManager.exactInputMirror(
            IPairPositionManager.SwapMirrorInputParams({
                poolId: id,
                zeroForOne: true,
                to: address(this),
                amountIn: 0.5e18,
                amountOutMin: 0,
                realOutMax: 0,
                deadline: block.timestamp
            })
        );
        _badDebt();

        _removeAllLiquidity();
        vault.setOperator(address(pairPositionManager), true);
        uint256 worth = helper.getMirrorShareAmount(id, true, shares);
        uint256 amount = pairPositionManager.redeemMirror(id, true, shares, address(this), 0, block.timestamp);
        assertEq(amount, worth);
        _assertConsistent();
    }

    /// A surplus too small to cover the shortfall is spent in full; the rest of the shortfall stays.
    function testSmallSurplus_SpentInFull() public {
        _donate(0.001e18, 0);
        (uint256 lost, Vm.Log[] memory logs) = _badDebt();

        (bool found, bool zeroForOne, uint256 amountIn, uint256 amountOut) = _rebalanceEvent(logs);
        assertTrue(found);
        assertTrue(zeroForOne);
        assertEq(amountIn, 0.001e18);
        assertLt(amountOut, lost);

        (int128 fund0, int128 fund1) = _funds();
        assertEq(fund0, 0);
        assertApproxEqAbs(fund1, -int128(int256(lost - amountOut)), 1);
        _assertConsistent();
    }

    /// A surplus on the same side as the loss absorbs it directly, no swap needed.
    function testSameSideSurplus_NoSwap() public {
        _donate(0, 1e18);
        (uint256 lost, Vm.Log[] memory logs) = _badDebt();
        (bool found,,,) = _rebalanceEvent(logs);
        assertFalse(found);

        (int128 fund0, int128 fund1) = _funds();
        assertEq(fund0, 0);
        assertApproxEqAbs(fund1, int128(int256(1e18 - lost)), 1);
        _assertConsistent();
    }

    /// A shortfall left from before is picked up by the next margin action once a surplus shows up.
    function testLaterSurplus_FilledOnNextMarginAction() public {
        (uint256 lost,) = _badDebt();
        _donate(1e18, 0); // donate itself does not rebalance
        (, int128 fund1) = _funds();
        assertApproxEqAbs(fund1, -int128(int256(lost)), 1);
        uint256 shortfall = uint256(-int256(fund1));

        // any margin action will do: open a small position
        token1.mint(address(this), 0.01e18);
        vm.recordLogs();
        marginPositionManager.addMargin(
            key,
            IMarginPositionManager.CreateParams({
                marginForOne: true,
                leverage: 2,
                marginAmount: 0.01e18,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        (bool found,,, uint256 amountOut) = _rebalanceEvent(vm.getRecordedLogs());
        assertTrue(found);
        assertEq(amountOut, shortfall);
        (, fund1) = _funds();
        assertEq(fund1, 0);
        _assertConsistent();
    }
    // ==================== audit regressions ====================
    // A hole left unfilled while LPs leave grows next to the pair. At spot price the fill shrank k, so the first
    // arbitrageur took LP value, a donor could trigger and back-run at a profit, and a shortfall above the pair's
    // reserve left it 1 wei. On the curve none of that works.

    function _pair() internal view returns (uint256 p0, uint256 p1) {
        (uint128 a, uint128 b) = StateLibrary.getPairReserves(vault, id).reserves();
        (p0, p1) = (a, b);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint256 amountOut) {
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

    function _open(bool marginForOne, uint24 leverage, uint128 marginAmount) internal returns (uint256 tokenId) {
        (marginForOne ? token1 : token0).mint(address(this), marginAmount);
        (tokenId,,) = marginPositionManager.addMargin(
            key,
            IMarginPositionManager.CreateParams({
                marginForOne: marginForOne,
                leverage: leverage,
                marginAmount: marginAmount,
                borrowAmountMax: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    /// token1 to sell into the pair to bring its price back to target0 / target1 (0.3% fee)
    function _token1InToRestore(uint256 target0, uint256 target1) internal view returns (uint256) {
        (uint256 p0, uint256 p1) = _pair();
        uint256 newP1 = Math.sqrt(Math.mulDiv(p0 * p1, target1, target0));
        if (newP1 <= p1) return 0;
        return (newP1 - p1) * 1e6 / (1e6 - 3000);
    }

    /// A token1 hole at a normal market: bad debt, then the price is walked back over a few blocks and the
    /// truncated price catches up. No token0 surplus, so the hole stays.
    function _holeAtNormalMarket() internal returns (uint256 hole) {
        (uint256 s0, uint256 s1) = _pair();
        uint256 tokenId = _open(false, 2, 0.4e18);
        skip(1000);
        _swap(true, 12e18);
        skip(1000);
        assertTrue(helper.checkMarginPositionLiquidate(tokenId));
        token1.mint(address(this), 100e18);
        marginPositionManager.liquidateCall(tokenId, block.timestamp);
        (, int128 fund1) = _funds();
        assertLt(fund1, 0);
        hole = uint256(-int256(fund1));
        for (uint256 i = 0; i < 20; i++) {
            skip(3600);
            uint256 amount = _token1InToRestore(s0, s1);
            if (amount < 1e12) break;
            (, uint256 p1) = _pair();
            if (amount > p1 / 20) amount = p1 / 20;
            _swap(false, amount);
        }
        skip(3600);
    }

    function _leave(uint256 bps) internal {
        pairPositionManager.removeLiquidity(
            lpTokenId, uint128(uint256(lpLiquidity) * bps / 10000), 0, 0, block.timestamp
        );
    }

    /// any margin action picks up the pending rebalance
    function _trigger() internal {
        _open(true, 1, 0.0001e18);
    }

    /// F1: with 90% of the liquidity gone a donor fills the hole; arbitraging the price back cannot take LP value.
    function testAudit_BackrunCannotTakeLPValue() public {
        _holeAtNormalMarket();
        _leave(9000);
        (uint256 p0, uint256 p1) = _pair();
        _donate(5e18, 0);
        _trigger();
        (, int128 fund1) = _funds();
        assertEq(fund1, 0);
        (uint256 a0, uint256 a1) = _pair();
        assertGe(a0 * a1, p0 * p1, "k fell");

        _swap(false, _token1InToRestore(p0, p1));
        (uint256 c0, uint256 c1) = _pair();
        // the LPs' pair, valued at the pre-trigger price, is worth no less than before
        assertGe(c0 + Math.mulDiv(c1, p0, p1), 2 * p0);
        _assertConsistent();
    }

    /// F1: a donor who fills the hole on the curve, triggers and back-runs in one go loses, even when the hole is
    /// almost the whole pair (at spot price this netted about a third of the remaining LP value).
    function testAudit_SelfFundedAttackLoses() public {
        uint256[2] memory leaves = [uint256(9800), 9810];
        for (uint256 i = 0; i < leaves.length; i++) {
            uint256 snapshot = vm.snapshotState();
            _holeAtNormalMarket();
            _leave(leaves[i]);
            (uint256 p0, uint256 p1) = _pair();
            (, int128 fund1) = _funds();
            uint256 shortfall = uint256(-int256(fund1));
            assertGt(shortfall * 10, p1 * 9, "hole should be over 90% of pair1");
            uint256 out = shortfall < p1 ? shortfall : p1 - 1;
            uint256 donation = Math.mulDivRoundingUp(p0, out, p1 - out) + 1e6;

            _donate(donation, 0);
            vm.recordLogs();
            _trigger();
            // the attacker only has to donate what the fill actually spends
            (bool found,, uint256 spentByFill,) = _rebalanceEvent(vm.getRecordedLogs());
            assertTrue(found);
            uint256 in1 = _token1InToRestore(p0, p1);
            uint256 out0 = _swap(false, in1);
            uint256 spent0 = spentByFill + Math.mulDivRoundingUp(in1 + 0.0001e18, p0, p1);
            assertLt(out0, spent0, "attack should lose");
            vm.revertToState(snapshot);
        }
    }

    /// F2: a shortfall above the pair's reserve and a surplus 100x the other side cannot take the pair down to
    /// wei; the next block's truncated reserves stay sane and level checks keep working.
    function testAudit_LargeShortfallCannotDrainPair() public {
        uint256 hole = _holeAtNormalMarket();
        // one ordinary position per side; the token1 collateral lets real1 cover a pair1 below the hole
        _open(false, 2, 0.01e18);
        uint256 token1Collateral = _open(true, 2, 0.3e18);
        skip(3600);
        _leave(9800);
        _swap(true, 0.05e18);
        (uint256 b0, uint256 b1) = _pair();
        assertLt(b1, hole);

        uint256 surplus = 100 * b0;
        _donate(surplus, 0);
        _trigger();
        (, uint256 a1) = _pair();
        assertGe(a1, b1 * b0 / (b0 + surplus));
        assertGt(a1, 1e12);
        _assertConsistent();

        skip(3);
        _swap(true, 1e9);
        (uint128 t0, uint128 t1) = StateLibrary.getTruncatedReserves(vault, id).reserves();
        assertGt(t0, 1e12);
        assertGt(t1, 1e12);
        // level checks still work (at 1 wei they reverted ReservesNotPositive). A full close would still wait on
        // the part of the hole the surplus could not buy: that is the first-come case, not a drained pair.
        helper.checkMarginPositionLiquidate(token1Collateral);
        token0.mint(address(this), 0.01e18);
        marginPositionManager.repay(token1Collateral, 0.01e18, block.timestamp);
    }
}
