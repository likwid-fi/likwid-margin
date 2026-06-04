// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {LikwidVault} from "../../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../../src/LikwidPairPosition.sol";
import {LikwidHelper} from "./LikwidHelper.sol";
import {LikwidMarginRouter} from "./LikwidMarginRouter.sol";
import {IMarginPositionManager} from "../../src/interfaces/IMarginPositionManager.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../../src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {MarginPosition} from "../../src/libraries/MarginPosition.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";

/// @notice Fund-flow and bookkeeping tests for {LikwidMarginRouter}.
/// @dev Covers both margin directions, ERC20 + native, the auto create-vs-add routing, the `positionOf`
///      index across mint/transfer/burn, negative auth, input refunds, and third-party liquidation.
contract LikwidMarginRouterTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    LikwidVault vault;
    LikwidMarginPosition marginPositionManager;
    LikwidPairPosition pairPositionManager;
    LikwidHelper helper;
    LikwidMarginRouter router;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolKey keyNative;

    uint24 leverage = 2;

    address user = makeAddr("user");
    address user2 = makeAddr("user2");

    event Wrapped(address indexed owner, uint256 indexed tokenId);
    event Unwrapped(address indexed owner, uint256 indexed tokenId, address indexed to);
    event Burned(address indexed owner, uint256 indexed tokenId);

    function setUp() public {
        vault = new LikwidVault(address(this));
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);

        address tokenA = address(new MockERC20("TokenA", "TKA", 18));
        address tokenB = address(new MockERC20("TokenB", "TKB", 18));
        (token0, token1) = tokenA < tokenB ? (MockERC20(tokenA), MockERC20(tokenB)) : (MockERC20(tokenB), MockERC20(tokenA));
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        vault.setMarginController(address(marginPositionManager));
        // The router caches `manager = vault.marginController()` in an immutable, so deploy it after the
        // controller is set.
        router = new LikwidMarginRouter(vault);

        // This contract is the liquidity provider / swapper.
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);

        uint256 amount0 = 10e18;
        uint256 amount1 = 20e18;

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, marginFee: 3000});
        vault.initialize(key);
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        pairPositionManager.addLiquidity(key, address(this), amount0, amount1, 0, 0, 10000);

        keyNative = PoolKey({currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: currency1, fee: 3000, marginFee: 3000});
        vault.initialize(keyNative);
        token1.mint(address(this), amount1);
        vm.deal(address(this), amount0);
        pairPositionManager.addLiquidity{value: amount0}(keyNative, address(this), amount0, amount1, 0, 0, 10000);
    }

    // ---------------------------------------------------------------- helpers

    function _marginAmount(PoolKey memory pk, bool marginForOne) internal view returns (uint256) {
        LikwidHelper.PoolStateInfo memory s = helper.getPoolStateInfo(pk.toId());
        return (marginForOne ? s.pairReserve1 : s.pairReserve0) / 180;
    }

    function _params(bool marginForOne, uint256 marginAmount)
        internal
        view
        returns (IMarginPositionManager.CreateParams memory)
    {
        return IMarginPositionManager.CreateParams({
            marginForOne: marginForOne,
            leverage: leverage,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(0), // ignored by the router
            deadline: block.timestamp
        });
    }

    /// @dev Give `who` `amount` of `currency` ready to spend through the router, and return the msg.value to
    ///      forward (native is sent as value; ERC20 is minted + approved to the router).
    function _fundInput(address who, Currency c, uint256 amount) internal returns (uint256 value) {
        if (c.isAddressZero()) {
            vm.deal(who, who.balance + amount);
            return amount;
        }
        MockERC20 t = MockERC20(Currency.unwrap(c));
        t.mint(who, amount);
        vm.prank(who);
        t.approve(address(router), amount);
        return 0;
    }

    /// @dev `who` opens or adds margin through the router for pool `pk`.
    function _open(address who, PoolKey memory pk, bool marginForOne) internal returns (uint256 id, uint256 borrow) {
        uint256 marginAmount = _marginAmount(pk, marginForOne);
        Currency mc = marginForOne ? pk.currency1 : pk.currency0;
        uint256 value = _fundInput(who, mc, marginAmount);
        vm.prank(who);
        (id, borrow,) = router.margin{value: value}(pk, _params(marginForOne, marginAmount), who);
    }

    function _repay(address who, PoolKey memory pk, uint256 id, bool marginForOne, uint256 repayAmount) internal {
        Currency debtC = marginForOne ? pk.currency0 : pk.currency1;
        uint256 value = _fundInput(who, debtC, repayAmount);
        vm.prank(who);
        router.repay{value: value}(id, repayAmount, block.timestamp);
    }

    function _modify(address who, PoolKey memory pk, uint256 id, bool marginForOne, int128 change) internal {
        uint256 value;
        if (change > 0) {
            Currency mc = marginForOne ? pk.currency1 : pk.currency0;
            value = _fundInput(who, mc, uint256(uint128(change)));
        }
        vm.prank(who);
        router.modify{value: value}(id, change, block.timestamp);
    }

    /// @dev The router must never retain funds after an operation.
    function _assertRouterEmpty() internal view {
        assertEq(token0.balanceOf(address(router)), 0, "router holds token0");
        assertEq(token1.balanceOf(address(router)), 0, "router holds token1");
        assertEq(address(router).balance, 0, "router holds native");
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : MockERC20(Currency.unwrap(c)).balanceOf(who);
    }

    // ---------------------------------------------------------------- create / index

    function test_margin_create_custodiesUnderlying_mintsMappingNFT() public {
        uint256 marginAmount = _marginAmount(key, false);
        token0.mint(user, marginAmount);

        vm.startPrank(user);
        token0.approve(address(router), marginAmount);
        (uint256 id, uint256 borrow,) = router.margin(key, _params(false, marginAmount), user);
        vm.stopPrank();

        assertGt(id, 0);
        assertGt(borrow, 0);
        assertEq(router.ownerOf(id), user, "mapping NFT owner");
        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), address(router), "underlying custodied");
        assertEq(router.positionOf(user, key.toId(), false), id, "positionOf set");
        uint256[] memory ids = router.tokensOfOwner(user);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        // exact conservation: deposited margin == marginAmount, user paid exactly that
        assertEq(marginPositionManager.getPositionState(id).marginAmount, marginAmount, "deposit matches input");
        assertEq(token0.balanceOf(user), 0, "user paid the margin");
        _assertRouterEmpty();
    }

    function test_margin_secondCall_autoAddsToExisting() public {
        (uint256 id1,) = _open(user, key, false);
        MarginPosition.State memory before = marginPositionManager.getPositionState(id1);

        (uint256 id2,) = _open(user, key, false);

        assertEq(id2, id1, "should add to the same position");
        assertEq(router.balanceOf(user), 1, "no new mapping NFT");
        MarginPosition.State memory aft = marginPositionManager.getPositionState(id1);
        assertGt(aft.debtAmount, before.debtAmount, "debt increased");
        assertGt(aft.marginAmount, before.marginAmount, "margin increased");
        _assertRouterEmpty();
    }

    /// @dev Regression: a collateral-only position (leverage == 0, borrowAmount == 0) has debtAmount == 0
    ///      but is NOT empty. A second margin() must add to it, not mint a duplicate.
    function test_margin_addsToZeroDebtCollateralPosition() public {
        IMarginPositionManager.CreateParams memory p = IMarginPositionManager.CreateParams({
            marginForOne: false,
            leverage: 0, // borrow mode
            marginAmount: 0,
            borrowAmount: 0, // no borrow -> zero debt
            borrowAmountMax: 0,
            recipient: address(0),
            deadline: block.timestamp
        });

        uint256 m1 = _marginAmount(key, false);
        token0.mint(user, m1);
        vm.startPrank(user);
        token0.approve(address(router), m1);
        p.marginAmount = uint128(m1);
        (uint256 id1,,) = router.margin(key, p, user);
        vm.stopPrank();

        MarginPosition.State memory s = marginPositionManager.getPositionState(id1);
        assertEq(s.debtAmount, 0, "no debt");
        assertGt(s.marginAmount, 0, "has collateral");
        assertEq(router.positionOf(user, key.toId(), false), id1);

        uint256 m2 = _marginAmount(key, false);
        token0.mint(user, m2);
        vm.startPrank(user);
        token0.approve(address(router), m2);
        p.marginAmount = uint128(m2);
        (uint256 id2,,) = router.margin(key, p, user);
        vm.stopPrank();

        assertEq(id2, id1, "added to existing zero-debt position, not duplicated");
        assertEq(router.balanceOf(user), 1, "no duplicate mapping NFT");
        assertGt(marginPositionManager.getPositionState(id1).marginAmount, s.marginAmount, "collateral grew");
        _assertRouterEmpty();
    }

    function test_margin_oppositeDirection_createsSeparatePosition() public {
        (uint256 id1,) = _open(user, key, false);
        (uint256 id2,) = _open(user, key, true);

        assertTrue(id2 != id1, "distinct positions");
        assertEq(router.balanceOf(user), 2);
        assertEq(router.positionOf(user, key.toId(), false), id1);
        assertEq(router.positionOf(user, key.toId(), true), id2);
        _assertRouterEmpty();
    }

    function test_margin_recipientDifferentFromCaller() public {
        uint256 marginAmount = _marginAmount(key, false);
        token0.mint(user, marginAmount);
        vm.startPrank(user);
        token0.approve(address(router), marginAmount);
        (uint256 id,,) = router.margin(key, _params(false, marginAmount), user2); // mapping NFT -> user2
        vm.stopPrank();

        assertEq(router.ownerOf(id), user2, "mapping NFT to recipient");
        // create-for-other is NOT auto-indexed under the recipient (only self-established positions are)
        assertEq(router.positionOf(user2, key.toId(), false), 0, "recipient not auto-indexed");
        assertEq(router.positionOf(user, key.toId(), false), 0, "caller has no index");
        assertEq(token0.balanceOf(user), 0, "caller paid");
        _assertRouterEmpty();
    }

    /// @dev M-1 fix: a transferred-in position is NOT auto-indexed, so the recipient's margin() opens a
    ///      fresh position instead of silently merging funds into a position they never vetted.
    function test_transferredInPosition_notAutoMerged() public {
        (uint256 id1,) = _open(user, key, false);

        vm.prank(user);
        router.transferFrom(user, user2, id1);

        assertEq(router.ownerOf(id1), user2, "NFT delivered");
        assertEq(router.positionOf(user, key.toId(), false), 0, "sender slot cleared");
        assertEq(router.positionOf(user2, key.toId(), false), 0, "transferred-in NOT indexed");

        // user2's margin must create a FRESH position, not add to the transferred-in id1
        (uint256 id2,) = _open(user2, key, false);
        assertTrue(id2 != id1, "fresh position, not merged into the transferred-in one");
        assertEq(router.positionOf(user2, key.toId(), false), id2, "the self-opened one is indexed");
        assertEq(router.balanceOf(user2), 2, "transferred-in + fresh");
        _assertRouterEmpty();
    }

    /// @dev The dangerous variant: a distressed (near-liquidation) position handed to a victim must not
    ///      become an auto-merge target for the victim's fresh margin.
    function test_distressedTransferIn_notIndexed() public {
        leverage = 4;
        (uint256 id1,) = _open(user, key, false);
        while (!helper.checkMarginPositionLiquidate(id1)) {
            _makeLiquidatable(false);
        }

        vm.prank(user);
        router.transferFrom(user, user2, id1);

        assertEq(router.ownerOf(id1), user2, "NFT delivered");
        assertEq(router.positionOf(user2, key.toId(), false), 0, "distressed transfer-in is NOT auto-indexed");
    }

    function test_closeFully_thenMargin_createsNew() public {
        (uint256 id1,) = _open(user, key, false);

        vm.prank(user);
        router.close(id1, 1_000_000, 0, block.timestamp);
        assertEq(marginPositionManager.getPositionState(id1).debtAmount, 0, "debt cleared");
        // full close empties the position -> mapping NFT auto-burned, index cleared
        assertEq(router.balanceOf(user), 0, "empty mapping NFT auto-burned");
        assertEq(router.positionOf(user, key.toId(), false), 0, "index cleared");

        (uint256 id2,) = _open(user, key, false);
        assertTrue(id2 != id1, "empty position -> create new");
        assertEq(router.positionOf(user, key.toId(), false), id2, "index repointed to new");
        assertEq(router.balanceOf(user), 1, "only the new mapping NFT");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------- burn

    function test_repay_full_autoBurnsEmptyPosition() public {
        (uint256 id, uint256 borrow) = _open(user, key, false);
        // over-repay => full settlement; the position becomes empty and its mapping NFT auto-burns
        _repay(user, key, id, false, borrow * 2);

        MarginPosition.State memory s = marginPositionManager.getPositionState(id);
        assertEq(s.debtAmount, 0, "debt cleared");
        assertEq(s.marginAmount, 0, "margin released");
        assertEq(s.marginTotal, 0, "marginTotal released");
        assertEq(router.balanceOf(user), 0, "mapping NFT auto-burned");
        assertEq(router.positionOf(user, key.toId(), false), 0, "index cleared");
        _assertRouterEmpty();
    }

    function test_repay_partial_doesNotBurn() public {
        (uint256 id, uint256 borrow) = _open(user, key, false);
        _repay(user, key, id, false, borrow / 2);
        assertGt(marginPositionManager.getPositionState(id).debtAmount, 0, "still has debt");
        assertEq(router.balanceOf(user), 1, "mapping NFT kept");
        assertEq(router.positionOf(user, key.toId(), false), id, "index kept");
    }

    function test_burn_emptyPositionAfterLiquidation() public {
        leverage = 4;
        (uint256 id,) = _open(user, key, false);
        while (!helper.checkMarginPositionLiquidate(id)) {
            _makeLiquidatable(false);
        }
        address liq = makeAddr("liq");
        vm.startPrank(liq);
        token1.mint(liq, 100e18);
        token1.approve(address(marginPositionManager), 100e18);
        marginPositionManager.liquidateCall(id, 0);
        vm.stopPrank();

        // emptied outside the router -> mapping NFT lingers until the owner cleans it up
        assertEq(router.balanceOf(user), 1, "mapping NFT still present");
        vm.prank(user);
        router.burn(id);
        assertEq(router.balanceOf(user), 0, "burned");
        assertEq(router.positionOf(user, key.toId(), false), 0, "index cleared");
    }

    function test_burn_revertsIfNotEmpty() public {
        (uint256 id,) = _open(user, key, false); // active position, debt > 0
        vm.prank(user);
        vm.expectRevert(LikwidMarginRouter.PositionNotEmpty.selector);
        router.burn(id);
    }

    // ---------------------------------------------------------------- repay / close / modify (both directions, ERC20)

    function test_repay_bothDirections_releasesMargin() public {
        for (uint256 d; d < 2; ++d) {
            bool marginForOne = d == 1;
            (uint256 id, uint256 borrow) = _open(user, key, marginForOne);
            Currency marginC = marginForOne ? currency1 : currency0; // released side
            uint256 marginBefore = _bal(marginC, user);
            MarginPosition.State memory before = marginPositionManager.getPositionState(id);

            _repay(user, key, id, marginForOne, borrow / 2);

            assertLt(marginPositionManager.getPositionState(id).debtAmount, before.debtAmount, "debt reduced");
            assertGt(_bal(marginC, user), marginBefore, "released margin swept to user");
            _assertRouterEmpty();
            skip(100);
        }
    }

    function test_repay_refundsExcessInput() public {
        (uint256 id, uint256 borrow) = _open(user, key, false); // debt currency = token1
        // over-fund: try to repay far more than the debt; the excess must be refunded
        uint256 repayAmount = borrow * 2;
        token1.mint(user, repayAmount);
        vm.startPrank(user);
        token1.approve(address(router), repayAmount);
        router.repay(id, repayAmount, block.timestamp);
        vm.stopPrank();

        assertApproxEqAbs(marginPositionManager.getPositionState(id).debtAmount, 0, 1, "debt fully repaid");
        assertGt(token1.balanceOf(user), 0, "excess debt currency refunded to user");
        _assertRouterEmpty();
    }

    function test_close_bothDirections_sweepsProceeds() public {
        for (uint256 d; d < 2; ++d) {
            bool marginForOne = d == 1;
            (uint256 id,) = _open(user, key, marginForOne);
            Currency marginC = marginForOne ? currency1 : currency0;
            uint256 balBefore = _bal(marginC, user);

            vm.prank(user);
            router.close(id, 1_000_000, 0, block.timestamp);

            assertEq(marginPositionManager.getPositionState(id).debtAmount, 0, "fully closed");
            assertGt(_bal(marginC, user), balBefore, "close proceeds swept to user");
            _assertRouterEmpty();
            skip(100);
        }
    }

    function test_modify_bothDirections_addAndRemove() public {
        for (uint256 d; d < 2; ++d) {
            bool marginForOne = d == 1;
            (uint256 id,) = _open(user, key, marginForOne);
            Currency marginC = marginForOne ? currency1 : currency0;
            uint256 delta = _marginAmount(key, marginForOne) / 2;

            MarginPosition.State memory before = marginPositionManager.getPositionState(id);
            _modify(user, key, id, marginForOne, int128(int256(delta)));
            assertEq(marginPositionManager.getPositionState(id).marginAmount, before.marginAmount + delta, "collateral added");
            _assertRouterEmpty();

            uint256 balBefore = _bal(marginC, user);
            _modify(user, key, id, marginForOne, -int128(int256(delta)));
            assertGt(_bal(marginC, user), balBefore, "withdrawn collateral swept to user");
            _assertRouterEmpty();
            skip(100);
        }
    }

    // ---------------------------------------------------------------- native variants

    function test_margin_native_create() public {
        uint256 marginAmount = _marginAmount(keyNative, false); // margin currency = native
        vm.deal(user, marginAmount);
        vm.prank(user);
        (uint256 id, uint256 borrow,) = router.margin{value: marginAmount}(keyNative, _params(false, marginAmount), user);

        assertGt(id, 0);
        assertGt(borrow, 0);
        assertEq(router.ownerOf(id), user);
        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), address(router));
        assertEq(router.positionOf(user, keyNative.toId(), false), id);
        assertEq(user.balance, 0, "user paid native margin");
        _assertRouterEmpty();
    }

    function test_repay_native_bothDirections() public {
        // margin native (false): debt = token1, repay token1, receive native
        {
            (uint256 id, uint256 borrow) = _open(user, keyNative, false);
            uint256 balBefore = user.balance;
            _repay(user, keyNative, id, false, borrow / 2);
            assertGt(user.balance, balBefore, "released native swept");
            _assertRouterEmpty();
        }
        // margin token1 (true): debt = native, repay with msg.value, receive token1
        {
            (uint256 id, uint256 borrow) = _open(user, keyNative, true);
            uint256 t1Before = token1.balanceOf(user);
            _repay(user, keyNative, id, true, borrow / 2);
            assertGt(token1.balanceOf(user), t1Before, "released token1 swept");
            _assertRouterEmpty();
        }
    }

    function test_close_native_receivesNative() public {
        (uint256 id,) = _open(user, keyNative, false); // margin native
        uint256 balBefore = user.balance;
        vm.prank(user);
        router.close(id, 1_000_000, 0, block.timestamp);
        assertGt(user.balance, balBefore, "received native back on close");
        _assertRouterEmpty();
    }

    function test_modify_native_addAndRemove() public {
        (uint256 id,) = _open(user, keyNative, false); // margin native
        uint256 delta = _marginAmount(keyNative, false) / 2;

        MarginPosition.State memory before = marginPositionManager.getPositionState(id);
        _modify(user, keyNative, id, false, int128(int256(delta))); // add via msg.value
        assertEq(marginPositionManager.getPositionState(id).marginAmount, before.marginAmount + delta);
        _assertRouterEmpty();

        uint256 balBefore = user.balance;
        _modify(user, keyNative, id, false, -int128(int256(delta))); // remove -> native swept
        assertGt(user.balance, balBefore, "withdrawn native swept to user");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------- wrap / unwrap

    function test_unwrap_returnsUnderlying() public {
        (uint256 id,) = _open(user, key, false);

        vm.prank(user);
        router.unwrap(id, user);

        assertEq(router.balanceOf(user), 0, "mapping NFT burned");
        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), user, "underlying returned");
        assertEq(router.positionOf(user, key.toId(), false), 0, "index cleared on burn");
    }

    function test_wrap_existingPosition() public {
        uint256 marginAmount = _marginAmount(key, false);
        token0.mint(user, marginAmount);
        vm.startPrank(user);
        token0.approve(address(marginPositionManager), marginAmount);
        IMarginPositionManager.CreateParams memory p = _params(false, marginAmount);
        p.recipient = user;
        (uint256 id,,) = marginPositionManager.addMargin(key, p);
        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), user, "user owns underlying");

        IERC721(address(marginPositionManager)).approve(address(router), id);
        router.wrap(id, user);
        vm.stopPrank();

        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), address(router), "router custodies");
        assertEq(router.ownerOf(id), user, "user holds mapping NFT");
        assertEq(router.positionOf(user, key.toId(), false), id, "index set on wrap");
    }

    function test_wrap_revertsWithoutApproval() public {
        uint256 marginAmount = _marginAmount(key, false);
        token0.mint(user, marginAmount);
        vm.startPrank(user);
        token0.approve(address(marginPositionManager), marginAmount);
        IMarginPositionManager.CreateParams memory p = _params(false, marginAmount);
        p.recipient = user;
        (uint256 id,,) = marginPositionManager.addMargin(key, p);

        // no approve() on the NFT -> the router's pull-in must revert
        vm.expectRevert();
        router.wrap(id, user);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- negative auth

    function test_operations_revertForNonOwner() public {
        (uint256 id,) = _open(user, key, false);

        vm.startPrank(user2); // user2 holds no mapping NFT for `id`
        vm.expectRevert(LikwidMarginRouter.NotAuthorized.selector);
        router.repay(id, 1, block.timestamp);
        vm.expectRevert(LikwidMarginRouter.NotAuthorized.selector);
        router.close(id, 1_000_000, 0, block.timestamp);
        vm.expectRevert(LikwidMarginRouter.NotAuthorized.selector);
        router.modify(id, int128(1), block.timestamp);
        vm.expectRevert(LikwidMarginRouter.NotAuthorized.selector);
        router.unwrap(id, user2);
        vm.stopPrank();
    }

    function test_onERC721Received_rejectsStrayNFT() public {
        MockNFT nft = new MockNFT();
        nft.mint(address(this), 1);
        vm.expectRevert(LikwidMarginRouter.NotAuthorized.selector);
        nft.safeTransferFrom(address(this), address(router), 1);
    }

    /// @dev Bypassing wrap() by safe-transferring an underlying position straight to the router must revert,
    ///      otherwise it would be received with no mapping NFT and get permanently stuck.
    function test_directManagerSafeTransfer_reverts() public {
        uint256 marginAmount = _marginAmount(key, false);
        token0.mint(user, marginAmount);
        vm.startPrank(user);
        token0.approve(address(marginPositionManager), marginAmount);
        IMarginPositionManager.CreateParams memory p = _params(false, marginAmount);
        p.recipient = user;
        (uint256 id,,) = marginPositionManager.addMargin(key, p);

        vm.expectRevert(LikwidMarginRouter.NotAuthorized.selector);
        IERC721(address(marginPositionManager)).safeTransferFrom(user, address(router), id);
        vm.stopPrank();

        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), user, "underlying stays with user");
    }

    function test_constructor_revertsWhenControllerUnset() public {
        LikwidVault freshVault = new LikwidVault(address(this)); // no setMarginController
        vm.expectRevert(LikwidMarginRouter.ControllerUnset.selector);
        new LikwidMarginRouter(freshVault);
    }

    function test_events_wrappedAndUnwrapped() public {
        // create directly on the manager (id known up front), then wrap/unwrap through the router
        uint256 marginAmount = _marginAmount(key, false);
        token0.mint(user, marginAmount);
        vm.startPrank(user);
        token0.approve(address(marginPositionManager), marginAmount);
        IMarginPositionManager.CreateParams memory p = _params(false, marginAmount);
        p.recipient = user;
        (uint256 id,,) = marginPositionManager.addMargin(key, p);

        IERC721(address(marginPositionManager)).approve(address(router), id);
        vm.expectEmit(true, true, false, true, address(router));
        emit Wrapped(user, id);
        router.wrap(id, user);

        vm.expectEmit(true, true, true, true, address(router));
        emit Unwrapped(user, id, user);
        router.unwrap(id, user);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- liquidation interaction

    function test_wrappedPosition_liquidatedThenUnwrap() public {
        leverage = 4;
        (uint256 id,) = _open(user, key, false);

        while (!helper.checkMarginPositionLiquidate(id)) {
            _makeLiquidatable(false);
        }

        // third party liquidates directly on the manager (permissionless; router custody doesn't block it)
        address liq = makeAddr("liq");
        vm.startPrank(liq);
        token1.mint(liq, 100e18);
        token1.approve(address(marginPositionManager), 100e18);
        marginPositionManager.liquidateCall(id, 0);
        vm.stopPrank();

        assertEq(marginPositionManager.getPositionState(id).debtAmount, 0, "position emptied");
        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), address(router), "router still custodies");
        assertEq(router.ownerOf(id), user, "user still holds mapping NFT");

        // user can still unwrap the now-empty position
        vm.prank(user);
        router.unwrap(id, user);
        assertEq(IERC721(address(marginPositionManager)).ownerOf(id), user, "underlying returned");
        assertEq(router.positionOf(user, key.toId(), false), 0, "index cleared");
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------- swap harness (for liquidation)

    function _makeLiquidatable(bool marginForOne) private {
        uint256 swapAmount = marginForOne ? 20e18 / 10 : 10e18 / 10;
        IVault.SwapParams memory swapParams;
        if (marginForOne) {
            token1.mint(address(this), swapAmount);
            swapParams = IVault.SwapParams({zeroForOne: false, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)});
        } else {
            token0.mint(address(this), swapAmount);
            swapParams = IVault.SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), useMirror: false, salt: bytes32(0)});
        }
        bytes memory inner = abi.encode(key, swapParams);
        bytes memory data = abi.encode(this.swap_callback.selector, inner);
        vault.unlock(data);
        skip(1000);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector, bytes memory params) = abi.decode(data, (bytes4, bytes));
        if (selector == this.swap_callback.selector) {
            (PoolKey memory _key, IVault.SwapParams memory swapParams) = abi.decode(params, (PoolKey, IVault.SwapParams));
            (BalanceDelta delta,,) = vault.swap(_key, swapParams);
            int256 a0 = delta.amount0();
            int256 a1 = delta.amount1();
            if (a0 < 0) {
                vault.sync(_key.currency0);
                IERC20(Currency.unwrap(_key.currency0)).transfer(address(vault), uint256(-a0));
                vault.settle();
            } else if (a0 > 0) {
                vault.take(_key.currency0, address(this), uint256(a0));
            }
            if (a1 < 0) {
                vault.sync(_key.currency1);
                IERC20(Currency.unwrap(_key.currency1)).transfer(address(vault), uint256(-a1));
                vault.settle();
            } else if (a1 > 0) {
                vault.take(_key.currency1, address(this), uint256(a1));
            }
        }
        return "";
    }

    function swap_callback(PoolKey memory, IVault.SwapParams memory) external pure {}

    receive() external payable {}
}

/// @dev A non-Likwid ERC721, used to verify the router rejects stray NFTs in onERC721Received.
contract MockNFT is ERC721 {
    constructor() ERC721("Mock", "MOCK") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}
