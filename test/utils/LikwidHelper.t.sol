// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockERC721} from "solmate/src/test/utils/mocks/MockERC721.sol";
import {ReentrantLockNFT} from "./ReentrantLockNFT.sol";

import {LikwidVault} from "../../src/LikwidVault.sol";
import {LikwidMarginPosition} from "../../src/LikwidMarginPosition.sol";
import {LikwidPairPosition} from "../../src/LikwidPairPosition.sol";
import {LikwidHelper} from "./LikwidHelper.sol";
import {IMarginPositionManager} from "../../src/interfaces/IMarginPositionManager.sol";
import {IPairPositionManager} from "../../src/interfaces/IPairPositionManager.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {FeeTypes} from "../../src/types/FeeTypes.sol";
import {PoolState} from "../../src/types/PoolState.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {InsuranceFunds} from "../../src/types/InsuranceFunds.sol";
import {MarginLevels} from "../../src/types/MarginLevels.sol";
import {StateLibrary} from "../../src/libraries/StateLibrary.sol";
import {MarginPosition} from "../../src/libraries/MarginPosition.sol";
import {SwapMath} from "../../src/libraries/SwapMath.sol";
import {InterestMath} from "../../src/libraries/InterestMath.sol";
import {Math} from "../../src/libraries/Math.sol";
import {PerLibrary} from "../../src/libraries/PerLibrary.sol";
import {CurrentStateLibrary} from "../../src/libraries/CurrentStateLibrary.sol";
import {ProtocolFeeLibrary} from "../../src/libraries/ProtocolFeeLibrary.sol";

contract LikwidHelperTest is Test {
    using PerLibrary for uint256;
    using ProtocolFeeLibrary for uint24;

    LikwidVault vault;
    LikwidMarginPosition marginPositionManager;
    LikwidPairPosition pairPositionManager;
    LikwidHelper public helper;
    PoolId public poolId;
    PoolKey public key;
    PoolKey public keyNative;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    receive() external payable {}

    function setUp() public {
        vault = new LikwidVault(address(this));
        marginPositionManager = new LikwidMarginPosition(address(this), vault);
        pairPositionManager = new LikwidPairPosition(address(this), vault);
        helper = new LikwidHelper(address(this), vault);
        vault.setMarginController(address(marginPositionManager));
        // Deploy mock tokens
        address tokenA = address(new MockERC20("TokenA", "TKNA", 18));
        address tokenB = address(new MockERC20("TokenB", "TKNB", 18));

        // Ensure currency order
        if (tokenA < tokenB) {
            token0 = MockERC20(tokenA);
            token1 = MockERC20(tokenB);
        } else {
            token0 = MockERC20(tokenB);
            token1 = MockERC20(tokenA);
        }

        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Approve the vault to pull funds from this test contract
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
        token0.approve(address(marginPositionManager), type(uint256).max);
        token1.approve(address(marginPositionManager), type(uint256).max);
        token0.approve(address(pairPositionManager), type(uint256).max);
        token1.approve(address(pairPositionManager), type(uint256).max);
        token0.approve(address(helper), type(uint256).max);
        token1.approve(address(helper), type(uint256).max);

        uint24 fee = 3000; // 0.3%
        key = PoolKey({currency0: currency0, currency1: currency1, fee: fee, marginFee: 3000});
        vault.initialize(key);
        poolId = key.toId();
        keyNative = PoolKey({currency0: CurrencyLibrary.ADDRESS_ZERO, currency1: currency1, fee: fee, marginFee: 3000});
        vault.initialize(keyNative);
        uint256 amount0ToAdd = 10e18;
        uint256 amount1ToAdd = 20e18;
        token0.mint(address(this), amount0ToAdd);
        token1.mint(address(this), amount1ToAdd);
        pairPositionManager.addLiquidity(key, address(this), amount0ToAdd, amount1ToAdd, 0, 0, 10000);
    }

    function testGetPoolStateInfo() public view {
        LikwidHelper.PoolStateInfo memory stateInfo = helper.getPoolStateInfo(poolId);
        uint256 amount0ToAdd = 10e18;
        uint256 amount1ToAdd = 20e18;
        assertEq(stateInfo.lastUpdated, 1);
        assertEq(stateInfo.lpFee, 3000);
        assertEq(stateInfo.marginFee, 3000);
        assertEq(stateInfo.protocolFee, vault.defaultProtocolFee());
        assertEq(stateInfo.realReserve0, amount0ToAdd, "stateInfo.realReserve0==amount0ToAdd");
        assertEq(stateInfo.realReserve1, amount1ToAdd, "stateInfo.realReserve1==amount1ToAdd");
        assertEq(stateInfo.mirrorReserve0, 0);
        assertEq(stateInfo.mirrorReserve1, 0);
        assertEq(stateInfo.pairReserve0, amount0ToAdd, "stateInfo.realReserve0==amount0ToAdd");
        assertEq(stateInfo.pairReserve1, amount1ToAdd, "stateInfo.realReserve1==amount1ToAdd");
        assertEq(stateInfo.truncatedReserve0, amount0ToAdd, "stateInfo.realReserve0==amount0ToAdd");
        assertEq(stateInfo.truncatedReserve1, amount1ToAdd, "stateInfo.realReserve1==amount1ToAdd");
        assertEq(stateInfo.lendReserve0, 0);
        assertEq(stateInfo.lendReserve1, 0);
        assertEq(stateInfo.interestReserve0, 0);
        assertEq(stateInfo.interestReserve1, 0);
    }

    function testChangePoolProtocolFee() public {
        FeeTypes feeType = FeeTypes.SWAP;
        uint8 newFee = 50;
        vault.setProtocolFee(key, feeType, 50);
        LikwidHelper.PoolStateInfo memory stateInfo = helper.getPoolStateInfo(poolId);
        assertNotEq(stateInfo.protocolFee, vault.defaultProtocolFee());
        assertEq(stateInfo.protocolFee, vault.defaultProtocolFee().setProtocolFee(feeType, newFee));
    }

    function testGetStageLiquidities() public view {
        uint128[][] memory liquidities = helper.getStageLiquidities(poolId);
        uint256 amount0ToAdd = 10e18;
        uint256 amount1ToAdd = 20e18;
        uint256 stage = (Math.sqrt(amount0ToAdd * amount1ToAdd) + 1000) / 5 + 1;
        assertEq(liquidities.length, 5);
        assertEq(liquidities[0][1], stage);
        uint256 releasedLiquidity = helper.getReleasedLiquidity(poolId);
        assertEq(releasedLiquidity, stage);
    }

    function testHelperGetAmountOut() public {
        bool zeroForOne = true;
        uint256 amountIn = 1e17;
        (uint256 amountOut,,) = helper.getAmountOut(poolId, zeroForOne, amountIn, false);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        (uint256 expectedAmountOut,) = SwapMath.getAmountOut(state.pairReserves, state.lpFee, zeroForOne, amountIn);
        assertEq(amountOut, expectedAmountOut);

        (amountOut,,) = helper.getAmountOut(poolId, zeroForOne, amountIn, true);
        (expectedAmountOut,,) =
            SwapMath.getAmountOut(state.pairReserves, state.truncatedReserves, state.lpFee, true, amountIn);
        assertEq(amountOut, expectedAmountOut);

        token0.mint(address(this), amountIn);

        IPairPositionManager.SwapInputParams memory params = IPairPositionManager.SwapInputParams({
            poolId: poolId,
            zeroForOne: zeroForOne,
            to: address(this),
            amountIn: amountIn,
            amountOutMin: 0,
            deadline: block.timestamp + 1
        });

        (,, uint256 actAmountOut) = pairPositionManager.exactInput(params);
        assertEq(actAmountOut, expectedAmountOut);
        assertEq(expectedAmountOut, token1.balanceOf(address(this)));
    }

    function testHelperGetAmountIn() public {
        bool zeroForOne = true;
        uint256 amountOut = 1e17;
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint256 amountIn,,) = helper.getAmountIn(poolId, zeroForOne, amountOut, false);
        (uint256 expectedAmountIn,) = SwapMath.getAmountIn(state.pairReserves, state.lpFee, zeroForOne, amountOut);
        assertEq(amountIn, expectedAmountIn);

        (amountIn,,) = helper.getAmountIn(poolId, zeroForOne, amountOut, true);
        (expectedAmountIn,,) =
            SwapMath.getAmountIn(state.pairReserves, state.truncatedReserves, state.lpFee, zeroForOne, amountOut);
        assertEq(amountIn, expectedAmountIn);

        token0.mint(address(this), amountIn);

        IPairPositionManager.SwapOutputParams memory params = IPairPositionManager.SwapOutputParams({
            poolId: poolId,
            zeroForOne: zeroForOne,
            to: address(this),
            amountInMax: 20e18,
            amountOut: amountOut,
            deadline: block.timestamp + 1
        });

        (,, uint256 actAmountIn) = pairPositionManager.exactOutput(params);

        assertEq(actAmountIn, expectedAmountIn);
        assertEq(amountOut, token1.balanceOf(address(this)));
    }

    function testGetBorrowRate() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        uint256 borrowRate = helper.getBorrowRate(poolId, true);
        (uint128 realReserve0,) = state.realReserves.reserves();
        (uint128 mirrorReserve0,) = state.mirrorReserves.reserves();
        uint256 borrowReserve = mirrorReserve0 + realReserve0;
        uint256 mirrorReserve = mirrorReserve0;

        uint256 expectedBorrowRate =
            InterestMath.getBorrowRateByReserves(state.marginState, borrowReserve, mirrorReserve);
        assertEq(borrowRate, expectedBorrowRate);
        assertTrue(expectedBorrowRate > 0);
    }

    function testGetPoolFees() public view {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);

        (uint24 fee, uint24 marginFee) = helper.getPoolFees(poolId, true, 1e17, 1e17);
        uint256 degree =
            SwapMath.getPriceDegree(state.pairReserves, state.truncatedReserves, state.lpFee, true, 1e17, 1e17);
        assertEq(fee, SwapMath.dynamicFee(state.lpFee, degree));
        assertEq(3000, state.marginFee);
        assertEq(marginFee, state.marginFee);
    }

    function testGetMaxDecrease() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory pos = marginPositionManager.getPositionState(tokenId);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        (uint128 pairReserve0, uint128 pairReserve1) = state.pairReserves.reserves();
        (uint256 reserveBorrow, uint256 reserveMargin) =
            pos.marginForOne ? (pairReserve0, pairReserve1) : (pairReserve1, pairReserve0);

        MarginLevels marginLevels = marginPositionManager.marginLevels();
        uint24 minBorrowLevel = marginLevels.minBorrowLevel();

        uint256 maxDecrease = helper.getMaxDecrease(tokenId);
        uint256 debtAmount = uint256(pos.debtAmount).mulDivMillion(minBorrowLevel);
        uint256 needAmount = Math.mulDiv(reserveMargin, debtAmount, reserveBorrow);
        uint256 assetAmount = pos.marginAmount + pos.marginTotal;
        uint256 expectedMax = assetAmount - needAmount;
        assertTrue(maxDecrease > 0);
        assertEq(maxDecrease, expectedMax);
    }

    function testMinMarginLevels() public view {
        MarginLevels marginLevels = marginPositionManager.marginLevels();
        (uint24 minMarginLevel, uint24 minBorrowLevel) = helper.minMarginLevels();
        assertEq(minMarginLevel, marginLevels.minMarginLevel());
        assertEq(minBorrowLevel, marginLevels.minBorrowLevel());
    }

    function testGetLiquidateRepayAmount() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);

        MarginPosition.State memory pos = marginPositionManager.getPositionState(tokenId);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        (uint128 pairReserve0, uint128 pairReserve1) = state.pairReserves.reserves();
        (uint256 reserveBorrow, uint256 reserveMargin) =
            pos.marginForOne ? (pairReserve0, pairReserve1) : (pairReserve1, pairReserve0);

        uint256 repayAmount = helper.getLiquidateRepayAmount(tokenId);
        uint256 expectedRepay = Math.mulDiv(reserveBorrow, pos.marginAmount + pos.marginTotal, reserveMargin);
        MarginLevels marginLevels = marginPositionManager.marginLevels();
        expectedRepay = expectedRepay.mulDivMillion(marginLevels.liquidationRatio());
        assertEq(repayAmount, expectedRepay);
    }

    function testGetLendingAPR() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        uint256 rate0 = helper.getLendingAPR(poolId, false, marginAmount);
        uint256 rate1 = helper.getLendingAPR(poolId, true, marginAmount);
        assertTrue(rate0 < rate1);
        assertTrue(rate0 == 0);
        (, uint256 reserve1) = state.pairReserves.reserves();
        (, uint256 lendReserve1) = state.lendReserves.reserves();
        uint256 allInterestReserve = marginAmount + reserve1 + lendReserve1;
        uint256 borrowRate = helper.getBorrowAPR(poolId, true);
        uint256 apr = Math.mulDiv(borrowRate, borrowAmount, allInterestReserve);
        assertLe(rate1, apr, "rate1 <= apr");
    }

    function testGetBorrowAPR() public {
        uint256 marginAmount = 0.1e18;
        token0.mint(address(this), marginAmount);

        IMarginPositionManager.CreateParams memory params = IMarginPositionManager.CreateParams({
            marginForOne: false, // margin with token0, borrow token1
            leverage: 2,
            marginAmount: uint128(marginAmount),
            borrowAmount: 0,
            borrowAmountMax: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        (uint256 tokenId, uint256 borrowAmount,) = marginPositionManager.addMargin(key, params);

        assertTrue(tokenId > 0);
        assertTrue(borrowAmount > 0);
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        uint256 rate0 = helper.getBorrowAPR(poolId, false);
        uint256 rate1 = helper.getBorrowAPR(poolId, true);
        assertTrue(rate0 < rate1);
        assertTrue(rate0 == state.marginState.rateBase());
    }

    function testHelperDonateCurrency0() public {
        uint256 donationAmount = 1e18;
        token0.mint(address(this), donationAmount);

        helper.donate(key, donationAmount, 0, 10000);

        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, poolId);
        assertEq(uint128(insuranceFunds.amount0()), donationAmount, "currency0 insurance fund should match donation");
        assertEq(uint128(insuranceFunds.amount1()), 0, "currency1 insurance fund should be untouched");
    }

    function testHelperDonateCurrency1() public {
        uint256 donationAmount = 2e18;
        token1.mint(address(this), donationAmount);

        helper.donate(key, 0, donationAmount, 10000);

        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, poolId);
        assertEq(uint128(insuranceFunds.amount0()), 0, "currency0 insurance fund should be untouched");
        assertEq(uint128(insuranceFunds.amount1()), donationAmount, "currency1 insurance fund should match donation");
    }

    function testHelperDonateBothCurrencies() public {
        uint256 donationAmount0 = 1e18;
        uint256 donationAmount1 = 3e18;
        token0.mint(address(this), donationAmount0);
        token1.mint(address(this), donationAmount1);

        helper.donate(key, donationAmount0, donationAmount1, 0);

        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, poolId);
        assertEq(uint128(insuranceFunds.amount0()), donationAmount0, "currency0 insurance fund should match donation");
        assertEq(uint128(insuranceFunds.amount1()), donationAmount1, "currency1 insurance fund should match donation");
    }

    function testHelperDonateZeroAmounts() public {
        helper.donate(key, 0, 0, 10000);

        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, poolId);
        assertEq(uint128(insuranceFunds.amount0()), 0, "currency0 insurance fund should be 0");
        assertEq(uint128(insuranceFunds.amount1()), 0, "currency1 insurance fund should be 0");
    }

    function testHelperDonateNative() public {
        // Add liquidity to the native pool first.
        uint256 nativeAmount0 = 5e18;
        uint256 nativeAmount1 = 5e18;
        token1.mint(address(this), nativeAmount1);
        vm.deal(address(this), nativeAmount0);
        pairPositionManager.addLiquidity{value: nativeAmount0}(
            keyNative, address(this), nativeAmount0, nativeAmount1, 0, 0, 10000
        );

        // Donate native currency0 + token1 via helper.
        uint256 donationNative = 1e18;
        uint256 donationToken1 = 2e18;
        token1.mint(address(this), donationToken1);
        vm.deal(address(this), donationNative);

        helper.donate{value: donationNative}(keyNative, donationNative, donationToken1, 10000);

        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, keyNative.toId());
        assertEq(uint128(insuranceFunds.amount0()), donationNative, "native insurance fund should match donation");
        assertEq(uint128(insuranceFunds.amount1()), donationToken1, "token1 insurance fund should match donation");
    }

    function test_RevertIf_HelperDonateExpired() public {
        uint256 donationAmount = 1e18;
        token0.mint(address(this), donationAmount);

        vm.warp(100);
        vm.expectRevert("EXPIRED");
        helper.donate(key, donationAmount, 0, block.timestamp - 1);
    }

    function test_RevertIf_HelperDonateNonNativeWithValue() public {
        uint256 donationAmount = 1e18;
        token0.mint(address(this), donationAmount);
        vm.deal(address(this), 1);

        vm.expectRevert(LikwidHelper.InsufficientNative.selector);
        helper.donate{value: 1}(key, donationAmount, 0, 10000);
    }

    function test_RevertIf_HelperDonateCurrenciesOutOfOrder() public {
        // Construct a PoolKey with the currencies swapped (currency0 > currency1).
        PoolKey memory badKey =
            PoolKey({currency0: currency1, currency1: currency0, fee: 3000, marginFee: 3000});

        vm.expectRevert(LikwidHelper.CurrenciesOutOfOrder.selector);
        helper.donate(badKey, 0, 0, 10000);
    }

    function test_RevertIf_HelperDonateNativeValueMismatch() public {
        uint256 donationAmount = 1e18;
        vm.deal(address(this), donationAmount);

        // Sending less native than amount0 must revert.
        vm.expectRevert(LikwidHelper.InsufficientNative.selector);
        helper.donate{value: donationAmount - 1}(keyNative, donationAmount, 0, 10000);
    }

    function test_RevertIf_UnlockCallbackNotVault() public {
        bytes memory data = abi.encode(address(this), key, uint256(0), uint256(0));

        vm.expectRevert(LikwidHelper.NotVault.selector);
        helper.unlockCallback(data);
    }

    // ******************** NFT LOCK TESTS ********************

    function _mintAndApproveNFT(MockERC721 nft, address owner, uint256 tokenId) internal {
        nft.mint(owner, tokenId);
        vm.prank(owner);
        nft.approve(address(helper), tokenId);
    }

    function testLockNFT() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 42;
        _mintAndApproveNFT(nft, alice, tokenId);

        uint64 lockDuration = 7 days;
        uint64 expectedLockedAt = uint64(block.timestamp);
        uint64 expectedUnlockAt = expectedLockedAt + lockDuration;

        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, lockDuration);

        assertEq(lockId, 1, "first lockId should be 1");
        assertEq(helper.nextLockId(), 2, "nextLockId should be incremented");
        assertEq(nft.ownerOf(tokenId), address(helper), "helper should hold the NFT");

        LikwidHelper.NFTLock memory info = helper.getNFTLock(lockId);
        assertEq(info.nftContract, address(nft));
        assertEq(info.tokenId, tokenId);
        assertEq(info.lockedAt, expectedLockedAt);
        assertEq(info.unlockAt, expectedUnlockAt);

        // The receipt NFT (lockId) should be owned by alice.
        assertEq(helper.ownerOf(lockId), alice, "alice should hold the receipt NFT");
        assertEq(helper.getRemainingLockTime(lockId), lockDuration);
    }

    function testLockNFTAssignsIncreasingIds() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        _mintAndApproveNFT(nft, alice, 1);
        _mintAndApproveNFT(nft, alice, 2);

        vm.startPrank(alice);
        uint256 lockId1 = helper.lockNFT(address(nft), 1, 1 days);
        uint256 lockId2 = helper.lockNFT(address(nft), 2, 1 days);
        vm.stopPrank();

        assertEq(lockId1, 1);
        assertEq(lockId2, 2);
        assertEq(helper.nextLockId(), 3);
    }

    function testUnlockNFTAfterExpiry() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 99;
        _mintAndApproveNFT(nft, alice, tokenId);

        uint64 lockDuration = 3 days;
        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, lockDuration);

        // Fast-forward past unlock time.
        vm.warp(block.timestamp + lockDuration + 1);

        assertEq(helper.getRemainingLockTime(lockId), 0, "remaining time should be 0 after expiry");

        vm.prank(alice);
        helper.unlockNFT(lockId);

        assertEq(nft.ownerOf(tokenId), alice, "alice should get NFT back");

        // Lock record should be deleted and receipt NFT burned.
        LikwidHelper.NFTLock memory info = helper.getNFTLock(lockId);
        assertEq(info.nftContract, address(0));
        assertEq(info.unlockAt, 0);
        vm.expectRevert();
        helper.ownerOf(lockId);
    }

    function test_RevertIf_LockNFTDurationZero() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        _mintAndApproveNFT(nft, alice, 1);

        vm.prank(alice);
        vm.expectRevert(LikwidHelper.InvalidLockDuration.selector);
        helper.lockNFT(address(nft), 1, 0);
    }

    function test_RevertIf_UnlockNFTBeforeExpiry() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 5;
        _mintAndApproveNFT(nft, alice, tokenId);

        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, 1 days);

        vm.prank(alice);
        vm.expectRevert(LikwidHelper.LockNotExpired.selector);
        helper.unlockNFT(lockId);
    }

    function test_RevertIf_UnlockNFTByNonOwner() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 tokenId = 7;
        _mintAndApproveNFT(nft, alice, tokenId);

        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, 1 days);

        vm.warp(block.timestamp + 2 days);

        vm.prank(bob);
        vm.expectRevert(LikwidHelper.NotLockOwner.selector);
        helper.unlockNFT(lockId);
    }

    function test_RevertIf_UnlockNFTLockNotFound() public {
        vm.expectRevert(LikwidHelper.LockNotFound.selector);
        helper.unlockNFT(123456);
    }

    function testGetRemainingLockTimeUnknownLockReturnsZero() public view {
        assertEq(helper.getRemainingLockTime(8888), 0);
    }

    function testGetRemainingLockTimeShrinks() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        _mintAndApproveNFT(nft, alice, 1);

        uint64 lockDuration = 10 days;
        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), 1, lockDuration);

        assertEq(helper.getRemainingLockTime(lockId), lockDuration);

        vm.warp(block.timestamp + 4 days);
        assertEq(helper.getRemainingLockTime(lockId), lockDuration - 4 days);

        vm.warp(block.timestamp + 6 days);
        assertEq(helper.getRemainingLockTime(lockId), 0);
    }

    function testLockAndUnlockNFTLongDuration() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 900;
        _mintAndApproveNFT(nft, alice, tokenId);

        uint64 lockDuration = 900 days;
        uint64 expectedLockedAt = uint64(block.timestamp);
        uint64 expectedUnlockAt = expectedLockedAt + lockDuration;

        // Lock for 900 days.
        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, lockDuration);

        assertEq(nft.ownerOf(tokenId), address(helper), "helper should hold the NFT");
        LikwidHelper.NFTLock memory info = helper.getNFTLock(lockId);
        assertEq(info.unlockAt, expectedUnlockAt);
        assertEq(helper.ownerOf(lockId), alice, "alice should hold the receipt NFT");
        assertEq(helper.getRemainingLockTime(lockId), lockDuration);

        // Halfway through (450 days) — still locked, cannot release.
        vm.warp(block.timestamp + 450 days);
        assertEq(helper.getRemainingLockTime(lockId), 450 days);
        vm.prank(alice);
        vm.expectRevert(LikwidHelper.LockNotExpired.selector);
        helper.unlockNFT(lockId);

        // One second before unlock — still locked.
        vm.warp(expectedUnlockAt - 1);
        assertEq(helper.getRemainingLockTime(lockId), 1);
        vm.prank(alice);
        vm.expectRevert(LikwidHelper.LockNotExpired.selector);
        helper.unlockNFT(lockId);

        // Exactly at unlockAt — releasable.
        vm.warp(expectedUnlockAt);
        assertEq(helper.getRemainingLockTime(lockId), 0);

        vm.prank(alice);
        helper.unlockNFT(lockId);

        assertEq(nft.ownerOf(tokenId), alice, "alice should get NFT back after 900 days");
        LikwidHelper.NFTLock memory cleared = helper.getNFTLock(lockId);
        assertEq(cleared.nftContract, address(0), "lock record should be cleared");
        assertEq(cleared.unlockAt, 0);
        vm.expectRevert();
        helper.ownerOf(lockId);
    }

    function testTransferReceiptTransfersUnlockRight() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 tokenId = 11;
        _mintAndApproveNFT(nft, alice, tokenId);

        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, 1 days);

        // Alice transfers the receipt NFT to Bob.
        vm.prank(alice);
        helper.transferFrom(alice, bob, lockId);
        assertEq(helper.ownerOf(lockId), bob, "bob should now hold the receipt");

        vm.warp(block.timestamp + 2 days);

        // Alice (no longer the receipt owner) cannot unlock.
        vm.prank(alice);
        vm.expectRevert(LikwidHelper.NotLockOwner.selector);
        helper.unlockNFT(lockId);

        // Bob can unlock and receives the underlying NFT.
        vm.prank(bob);
        helper.unlockNFT(lockId);
        assertEq(nft.ownerOf(tokenId), bob, "bob should receive the underlying NFT");
    }

    function testRelockAfterUnlock() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 1;
        _mintAndApproveNFT(nft, alice, tokenId);

        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, 1 days);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        helper.unlockNFT(lockId);

        // Re-approve and lock again — should get a new lock id.
        vm.prank(alice);
        nft.approve(address(helper), tokenId);
        vm.prank(alice);
        uint256 lockId2 = helper.lockNFT(address(nft), tokenId, 2 days);

        assertEq(lockId2, lockId + 1);
        assertEq(nft.ownerOf(tokenId), address(helper));
    }

    function testRescueDirectlyDepositedNFT() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        address rescueTo = makeAddr("rescueTo");
        uint256 tokenId = 555;

        // Alice mints and accidentally safe-transfers the NFT directly to the
        // helper, bypassing lockNFT.
        nft.mint(alice, tokenId);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(helper), tokenId);
        assertEq(nft.ownerOf(tokenId), address(helper));

        // Owner (this contract) rescues it.
        helper.rescueNFT(address(nft), tokenId, rescueTo);
        assertEq(nft.ownerOf(tokenId), rescueTo, "NFT should be rescued to recipient");
    }

    function test_RevertIf_RescueNFTNotOwner() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 1;
        nft.mint(alice, tokenId);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(helper), tokenId);

        // Non-owner cannot rescue.
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        helper.rescueNFT(address(nft), tokenId, alice);
    }

    function test_RevertIf_RescueNFTStillLocked() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 7;
        _mintAndApproveNFT(nft, alice, tokenId);

        // Alice properly locks the NFT.
        vm.prank(alice);
        helper.lockNFT(address(nft), tokenId, 1 days);

        // Owner cannot rescue an actively-locked NFT.
        vm.expectRevert(LikwidHelper.UnderlyingStillLocked.selector);
        helper.rescueNFT(address(nft), tokenId, address(this));

        // Underlying NFT is still held by helper.
        assertEq(nft.ownerOf(tokenId), address(helper));
    }

    function test_RevertIf_LockNFTDurationOverflow() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        _mintAndApproveNFT(nft, alice, 1);

        // Make `block.timestamp + lockDuration` overflow uint64.
        vm.warp(100);
        uint64 hugeDuration = type(uint64).max - 50; // 100 + (max-50) = max + 50 → overflow

        vm.prank(alice);
        vm.expectRevert(LikwidHelper.InvalidLockDuration.selector);
        helper.lockNFT(address(nft), 1, hugeDuration);
    }

    function testLockExistsAndQueryConsistency() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        _mintAndApproveNFT(nft, alice, 1);

        // Unknown id: lockExists==false, getRemainingLockTime==0, getNFTLock zero struct.
        assertFalse(helper.lockExists(9999));
        assertEq(helper.getRemainingLockTime(9999), 0);
        assertEq(helper.getNFTLock(9999).nftContract, address(0));

        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), 1, 1 days);

        // Active lock: lockExists==true, remaining > 0, struct populated.
        assertTrue(helper.lockExists(lockId));
        assertGt(helper.getRemainingLockTime(lockId), 0);
        assertEq(helper.getNFTLock(lockId).nftContract, address(nft));

        // After expiry but before unlock: still exists, remaining == 0.
        vm.warp(block.timestamp + 2 days);
        assertTrue(helper.lockExists(lockId));
        assertEq(helper.getRemainingLockTime(lockId), 0);

        // After unlock: lockExists==false again.
        vm.prank(alice);
        helper.unlockNFT(lockId);
        assertFalse(helper.lockExists(lockId));
        assertEq(helper.getRemainingLockTime(lockId), 0);
        assertEq(helper.getNFTLock(lockId).nftContract, address(0));
    }

    function test_RevertIf_LockNFTReentrantDoubleLock() public {
        // A malicious ERC721 that re-enters helper.lockNFT from inside its
        // own safeTransferFrom should be rejected by the new
        // _lockedBy guard. Without the guard, the inner call would be
        // able to overwrite _lockedBy[nft][tokenId] with a second lockId
        // and confuse rescueNFT later.
        ReentrantLockNFT nft = new ReentrantLockNFT();
        address alice = makeAddr("alice");
        uint256 tokenId = 1;
        nft.mint(alice, tokenId);
        vm.prank(alice);
        nft.approve(address(helper), tokenId);

        nft.setTarget(address(helper));
        nft.setReenter(true);

        vm.prank(alice);
        vm.expectRevert(LikwidHelper.UnderlyingAlreadyLocked.selector);
        helper.lockNFT(address(nft), tokenId, 1 days);
    }

    function testRescueAfterUnlockAllowed() public {
        MockERC721 nft = new MockERC721("MockNFT", "MNFT");
        address alice = makeAddr("alice");
        uint256 tokenId = 9;
        _mintAndApproveNFT(nft, alice, tokenId);

        vm.prank(alice);
        uint256 lockId = helper.lockNFT(address(nft), tokenId, 1 days);

        // Alice unlocks normally — _lockedBy should be cleared.
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        helper.unlockNFT(lockId);
        assertEq(nft.ownerOf(tokenId), alice);

        // Alice re-deposits accidentally (not via lockNFT) and owner rescues.
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(helper), tokenId);
        helper.rescueNFT(address(nft), tokenId, alice);
        assertEq(nft.ownerOf(tokenId), alice);
    }
}
