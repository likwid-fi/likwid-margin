// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// Solmate
import {Owned} from "solmate/src/auth/Owned.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {PoolState} from "../../src/types/PoolState.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {MarginLevels} from "../../src/types/MarginLevels.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IUnlockCallback} from "../../src/interfaces/callback/IUnlockCallback.sol";
import {IMarginPositionManager} from "../../src/interfaces/IMarginPositionManager.sol";
import {IMarginBase} from "../../src/interfaces/IMarginBase.sol";
import {MarginState} from "../../src/types/MarginState.sol";
import {InsuranceFunds} from "../../src/types/InsuranceFunds.sol";
import {Math} from "../../src/libraries/Math.sol";
import {StateLibrary} from "../../src/libraries/StateLibrary.sol";
import {CurrentStateLibrary} from "../../src/libraries/CurrentStateLibrary.sol";
import {CurrencyPoolLibrary} from "../../src/libraries/CurrencyPoolLibrary.sol";
import {PerLibrary} from "../../src/libraries/PerLibrary.sol";
import {SwapMath} from "../../src/libraries/SwapMath.sol";
import {StageMath} from "../../src/libraries/StageMath.sol";
import {InterestMath} from "../../src/libraries/InterestMath.sol";
import {MarginPosition} from "../../src/libraries/MarginPosition.sol";

contract LikwidHelper is Owned, IUnlockCallback, IERC721Receiver, ERC721 {
    using MarginPosition for MarginPosition.State;
    using PerLibrary for uint256;
    using StageMath for uint256;
    using CurrencyPoolLibrary for Currency;

    IVault public immutable vault;

    constructor(address initialOwner, IVault _vault) Owned(initialOwner) ERC721("Likwid Lock Receipt", "LLR") {
        vault = _vault;
    }

    struct PoolStateInfo {
        uint128 totalSupply;
        uint32 lastUpdated;
        uint24 lpFee;
        uint24 marginFee;
        uint24 protocolFee;
        uint128 realReserve0;
        uint128 realReserve1;
        uint128 mirrorReserve0;
        uint128 mirrorReserve1;
        uint128 pairReserve0;
        uint128 pairReserve1;
        uint128 truncatedReserve0;
        uint128 truncatedReserve1;
        uint128 lendReserve0;
        uint128 lendReserve1;
        uint128 interestReserve0;
        uint128 interestReserve1;
        int128 insuranceFund0;
        int128 insuranceFund1;
        uint256 borrow0CumulativeLast;
        uint256 borrow1CumulativeLast;
        uint256 deposit0CumulativeLast;
        uint256 deposit1CumulativeLast;
    }

    function getPoolStateInfo(PoolId poolId) external view returns (PoolStateInfo memory stateInfo) {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        stateInfo.totalSupply = state.totalSupply;
        stateInfo.lastUpdated = state.lastUpdated;
        stateInfo.lpFee = state.lpFee;
        stateInfo.marginFee = state.marginFee;
        stateInfo.protocolFee = state.protocolFee;
        (uint128 realReserve0, uint128 realReserve1) = state.realReserves.reserves();
        stateInfo.realReserve0 = realReserve0;
        stateInfo.realReserve1 = realReserve1;
        (uint128 mirrorReserve0, uint128 mirrorReserve1) = state.mirrorReserves.reserves();
        stateInfo.mirrorReserve0 = mirrorReserve0;
        stateInfo.mirrorReserve1 = mirrorReserve1;
        (uint128 pairReserve0, uint128 pairReserve1) = state.pairReserves.reserves();
        stateInfo.pairReserve0 = pairReserve0;
        stateInfo.pairReserve1 = pairReserve1;
        (uint128 truncatedReserve0, uint128 truncatedReserve1) = state.truncatedReserves.reserves();
        stateInfo.truncatedReserve0 = truncatedReserve0;
        stateInfo.truncatedReserve1 = truncatedReserve1;
        (uint128 lendReserve0, uint128 lendReserve1) = state.lendReserves.reserves();
        stateInfo.lendReserve0 = lendReserve0;
        stateInfo.lendReserve1 = lendReserve1;
        (uint128 interestReserve0, uint128 interestReserve1) = state.interestReserves.reserves();
        stateInfo.interestReserve0 = interestReserve0;
        stateInfo.interestReserve1 = interestReserve1;

        InsuranceFunds insuranceFunds = StateLibrary.getInsuranceFunds(vault, poolId);
        stateInfo.insuranceFund0 = insuranceFunds.amount0();
        stateInfo.insuranceFund1 = insuranceFunds.amount1();

        stateInfo.borrow0CumulativeLast = state.borrow0CumulativeLast;
        stateInfo.borrow1CumulativeLast = state.borrow1CumulativeLast;
        stateInfo.deposit0CumulativeLast = state.deposit0CumulativeLast;
        stateInfo.deposit1CumulativeLast = state.deposit1CumulativeLast;
    }

    function getAmountOut(PoolId poolId, bool zeroForOne, uint256 amountIn, bool dynamicFee)
        external
        view
        returns (uint256 amountOut, uint24 fee, uint256 feeAmount)
    {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        fee = state.lpFee;
        if (!dynamicFee) {
            (amountOut, feeAmount) = SwapMath.getAmountOut(state.pairReserves, fee, zeroForOne, amountIn);
        } else {
            (amountOut, fee, feeAmount) =
                SwapMath.getAmountOut(state.pairReserves, state.truncatedReserves, fee, zeroForOne, amountIn);
        }
    }

    function getAmountIn(PoolId poolId, bool zeroForOne, uint256 amountOut, bool dynamicFee)
        external
        view
        returns (uint256 amountIn, uint24 fee, uint256 feeAmount)
    {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        fee = state.lpFee;
        if (!dynamicFee) {
            (amountIn, feeAmount) = SwapMath.getAmountIn(state.pairReserves, fee, zeroForOne, amountOut);
        } else {
            (amountIn, fee, feeAmount) =
                SwapMath.getAmountIn(state.pairReserves, state.truncatedReserves, fee, zeroForOne, amountOut);
        }
    }

    function _getBorrowRate(PoolState memory state, uint256 inputAmount, bool marginForOne)
        internal
        pure
        returns (uint256)
    {
        (uint128 realReserve0, uint128 realReserve1) = state.realReserves.reserves();
        (uint128 mirrorReserve0, uint128 mirrorReserve1) = state.mirrorReserves.reserves();
        uint256 borrowReserve;
        uint256 mirrorReserve;
        if (marginForOne) {
            mirrorReserve = mirrorReserve0;
            borrowReserve = mirrorReserve0 + realReserve0 + inputAmount;
        } else {
            mirrorReserve = mirrorReserve1;
            borrowReserve = mirrorReserve1 + realReserve1 + inputAmount;
        }
        return InterestMath.getBorrowRateByReserves(state.marginState, borrowReserve, mirrorReserve);
    }

    function getBorrowRate(PoolId poolId, bool marginForOne) external view returns (uint256) {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        return _getBorrowRate(state, 0, marginForOne);
    }

    function getPoolFees(PoolId poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut)
        external
        view
        returns (uint24 _fee, uint24 _marginFee)
    {
        PoolState memory state = CurrentStateLibrary.getState(vault, poolId);
        uint256 degree = SwapMath.getPriceDegree(
            state.pairReserves, state.truncatedReserves, state.lpFee, zeroForOne, amountIn, amountOut
        );
        _fee = SwapMath.dynamicFee(state.lpFee, degree);
        _marginFee = state.marginFee;
    }

    function _getMaxDecrease(
        IMarginPositionManager manager,
        PoolState memory _state,
        MarginPosition.State memory _position
    ) internal view returns (uint256 maxAmount) {
        MarginLevels marginLevels = manager.marginLevels();
        uint24 minBorrowLevel = marginLevels.minBorrowLevel();
        (uint128 pairReserve0, uint128 pairReserve1) = _state.pairReserves.reserves();
        (uint256 reserveBorrow, uint256 reserveMargin) =
            _position.marginForOne ? (pairReserve0, pairReserve1) : (pairReserve1, pairReserve0);
        uint256 needAmount;
        uint256 debtAmount = uint256(_position.debtAmount).mulDivMillion(minBorrowLevel);
        if (_position.marginTotal > 0) {
            needAmount = Math.mulDiv(reserveMargin, debtAmount, reserveBorrow);
        } else {
            (needAmount,) = SwapMath.getAmountIn(_state.pairReserves, _state.lpFee, !_position.marginForOne, debtAmount);
        }
        uint256 assetAmount = _position.marginAmount + _position.marginTotal;

        if (needAmount < assetAmount) {
            maxAmount = assetAmount - needAmount;
        }
        maxAmount = Math.min(uint256(_position.marginAmount), maxAmount);
    }

    function getMaxDecrease(uint256 tokenId) external view returns (uint256 maxAmount) {
        IMarginPositionManager manager = IMarginPositionManager(vault.marginController());
        MarginPosition.State memory _position = manager.getPositionState(tokenId);
        PoolId poolId = manager.poolIds(tokenId);
        PoolState memory _state = CurrentStateLibrary.getState(vault, poolId);
        maxAmount = _getMaxDecrease(manager, _state, _position);
    }

    function minMarginLevels() external view returns (uint24 minMarginLevel, uint24 minBorrowLevel) {
        MarginLevels marginLevels = IMarginPositionManager(vault.marginController()).marginLevels();
        minMarginLevel = marginLevels.minMarginLevel();
        minBorrowLevel = marginLevels.minBorrowLevel();
    }

    function getLiquidateRepayAmount(uint256 tokenId) external view returns (uint256 repayAmount) {
        IMarginPositionManager manager = IMarginPositionManager(vault.marginController());
        MarginPosition.State memory _position = manager.getPositionState(tokenId);
        PoolId poolId = manager.poolIds(tokenId);
        PoolState memory _state = CurrentStateLibrary.getState(vault, poolId);
        (uint128 pairReserve0, uint128 pairReserve1) = _state.pairReserves.reserves();
        (uint256 reserveBorrow, uint256 reserveMargin) =
            _position.marginForOne ? (pairReserve0, pairReserve1) : (pairReserve1, pairReserve0);
        repayAmount = Math.mulDiv(reserveBorrow, _position.marginAmount + _position.marginTotal, reserveMargin);
        MarginLevels marginLevels = manager.marginLevels();
        repayAmount = repayAmount.mulDivMillion(marginLevels.liquidationRatio());
    }

    function getLendingAPR(PoolId poolId, bool borrowForOne, uint256 inputAmount) public view returns (uint256 apr) {
        PoolState memory _state = CurrentStateLibrary.getState(vault, poolId);
        (uint128 mirrorReserve0, uint128 mirrorReserve1) = _state.mirrorReserves.reserves();
        uint256 mirrorReserve = borrowForOne ? mirrorReserve1 : mirrorReserve0;
        uint256 borrowRate = _getBorrowRate(_state, inputAmount, !borrowForOne);
        (uint256 reserve0, uint256 reserve1) = _state.pairReserves.reserves();
        (uint256 lendReserve0, uint256 lendReserve1) = _state.lendReserves.reserves();
        uint256 flowReserve = borrowForOne ? reserve1 : reserve0;
        uint256 totalSupply = borrowForOne ? lendReserve1 : lendReserve0;
        uint256 allInterestReserve = flowReserve + inputAmount + totalSupply;
        if (allInterestReserve > 0) {
            apr = Math.mulDiv(borrowRate, mirrorReserve, allInterestReserve);
        }
    }

    function getBorrowAPR(PoolId poolId, bool borrowForOne) external view returns (uint256 rate) {
        PoolState memory _state = CurrentStateLibrary.getState(vault, poolId);
        (uint256 realReserve0, uint256 realReserve1) = _state.realReserves.reserves();
        (uint256 mirrorReserve0, uint256 mirrorReserve1) = _state.mirrorReserves.reserves();
        rate = borrowForOne
            ? InterestMath.getBorrowRateByReserves(_state.marginState, realReserve1 + mirrorReserve1, mirrorReserve1)
            : InterestMath.getBorrowRateByReserves(_state.marginState, realReserve0 + mirrorReserve0, mirrorReserve0);
    }

    function getStageLiquidities(PoolId poolId) external view returns (uint128[][] memory liquidities) {
        uint256[] memory queue = StateLibrary.getRawStageLiquidities(vault, poolId);
        liquidities = new uint128[][](queue.length);
        for (uint256 i = 0; i < queue.length; i++) {
            (uint128 total, uint128 liquidity) = queue[i].decode();
            liquidities[i] = new uint128[](2);
            liquidities[i][0] = total;
            liquidities[i][1] = liquidity;
        }
    }

    function getReleasedLiquidity(PoolId id) external view returns (uint128) {
        IMarginBase marginBase = IMarginBase(address(vault));
        MarginState marginState = marginBase.marginState();
        uint128 releasedLiquidity;
        uint128 nextReleasedLiquidity;
        releasedLiquidity = type(uint128).max;
        if (uint256(marginState.stageDuration()) * marginState.stageSize() > 0) {
            uint256[] memory queue = StateLibrary.getRawStageLiquidities(vault, id);
            uint256 lastStageTimestamp = StateLibrary.getLastStageTimestamp(vault, id);

            if (queue.length > 0) {
                uint256 currentStage = queue[0];
                (, releasedLiquidity) = StageMath.decode(currentStage);
                if (
                    queue.length > 1 && StageMath.isFree(currentStage, marginState.stageLeavePart())
                        && block.timestamp >= lastStageTimestamp + marginState.stageDuration()
                ) {
                    uint256 nextStage = queue[1];
                    (, nextReleasedLiquidity) = StageMath.decode(nextStage);
                }
            }
        }
        return releasedLiquidity + nextReleasedLiquidity;
    }

    function getStageState(PoolId id)
        external
        view
        returns (uint24 stageSize, uint24 stageLeavePart, uint24 stageDuration, uint256 lastStageTimestamp)
    {
        IMarginBase marginBase = IMarginBase(address(vault));
        MarginState marginState = marginBase.marginState();
        stageSize = marginState.stageSize();
        stageLeavePart = marginState.stageLeavePart();
        stageDuration = marginState.stageDuration();
        lastStageTimestamp = StateLibrary.getLastStageTimestamp(vault, id);
    }

    function checkMarginPositionLiquidate(uint256 tokenId) external view returns (bool liquidated) {
        IMarginPositionManager manager = IMarginPositionManager(vault.marginController());
        MarginPosition.State memory _position = manager.getPositionState(tokenId);
        PoolId poolId = manager.poolIds(tokenId);
        PoolState memory _state = CurrentStateLibrary.getState(vault, poolId);
        uint256 level = _position.marginLevel(
            _state.truncatedReserves, _position.borrowCumulativeLast, _position.depositCumulativeLast
        );
        liquidated = level <= manager.marginLevels().liquidateLevel();
    }

    // ******************** VAULT CALL ********************

    error NotVault();
    error InsufficientNative();
    error CurrenciesOutOfOrder();

    modifier ensure(uint256 deadline) {
        _ensure(deadline);
        _;
    }

    function _ensure(uint256 deadline) internal view {
        require(deadline == 0 || deadline >= block.timestamp, "EXPIRED");
    }

    /// @notice Only allow calls from the LikwidVault contract
    modifier onlyVault() {
        _onlyVault();
        _;
    }

    function _onlyVault() internal view {
        if (msg.sender != address(vault)) revert NotVault();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyVault returns (bytes memory) {
        return _handleDonate(data);
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        payable
        ensure(deadline)
    {
        // Enforce canonical PoolKey ordering: currency0 < currency1. This
        // also implies currency1 cannot be the native sentinel (address(0)),
        // so msg.value can only ever be tied to currency0.
        if (!(key.currency0 < key.currency1)) revert CurrenciesOutOfOrder();
        if (CurrencyLibrary.isAddressZero(key.currency0)) {
            if (msg.value != amount0) {
                revert InsufficientNative();
            }
        } else if (msg.value != 0) {
            revert InsufficientNative();
        }
        bytes memory callbackData = abi.encode(msg.sender, key, amount0, amount1);
        vault.unlock(callbackData);
    }

    function _handleDonate(bytes memory _data) internal returns (bytes memory) {
        (address sender, PoolKey memory key, uint256 amount0, uint256 amount1) =
            abi.decode(_data, (address, PoolKey, uint256, uint256));

        (BalanceDelta delta) = vault.donate(key, amount0, amount1);

        if (delta.amount0() < 0) {
            key.currency0.settle(vault, sender, amount0, false);
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(vault, sender, amount1, false);
        }

        return abi.encode(amount0, amount1);
    }

    // ******************** NFT LOCK ********************

    /// @dev The lock receipt is itself an ERC721 token minted by this contract.
    ///      The owner of the receipt (lockId) is, by definition, the owner of
    ///      the lock — so the receipt can be freely transferred and the new
    ///      receipt holder gains the right to release the underlying NFT
    ///      after expiry.
    struct NFTLock {
        address nftContract;
        uint256 tokenId;
        uint64 lockedAt;
        uint64 unlockAt;
    }

    /// @notice Auto-incrementing identifier for NFT locks. Each id corresponds
    ///         to an ERC721 receipt minted by this contract.
    uint256 public nextLockId = 1;

    /// @notice Lock id => lock record. A lock is considered released once the
    ///         record is deleted (nftContract == address(0)).
    mapping(uint256 => NFTLock) private _nftLocks;

    /// @notice (nftContract, tokenId) => lockId of an active lock, or 0 if
    ///         the underlying NFT is not currently part of any lock. Used by
    ///         {rescueNFT} to prevent the owner from pulling out NFTs that
    ///         belong to a live lock receipt.
    mapping(address => mapping(uint256 => uint256)) private _lockedBy;

    error InvalidLockDuration();
    error InvalidNFTContract();
    error LockNotFound();
    error LockNotExpired();
    error NotLockOwner();
    error UnderlyingAlreadyLocked();
    error UnderlyingStillLocked();

    event NFTLocked(
        uint256 indexed lockId,
        address indexed owner,
        address indexed nftContract,
        uint256 tokenId,
        uint64 lockedAt,
        uint64 unlockAt
    );

    event NFTUnlocked(uint256 indexed lockId, address indexed owner, address indexed nftContract, uint256 tokenId);

    event NFTRescued(address indexed nftContract, uint256 indexed tokenId, address indexed to);

    /// @notice Lock an ERC721 token in this contract for `lockDuration` seconds.
    ///         The caller must own the token and have approved this contract
    ///         to transfer it. A receipt NFT (this contract's own ERC721 with
    ///         id == lockId) is minted to the caller; whoever holds that
    ///         receipt may call {unlockNFT} after expiry to retrieve the
    ///         underlying token.
    /// @param nftContract The ERC721 contract address.
    /// @param tokenId The token id to lock.
    /// @param lockDuration Number of seconds the token will remain locked.
    /// @return lockId Identifier of the newly created lock record (also the
    ///         receipt token id).
    function lockNFT(address nftContract, uint256 tokenId, uint64 lockDuration) external returns (uint256 lockId) {
        if (lockDuration == 0) revert InvalidLockDuration();
        if (nftContract == address(0)) revert InvalidNFTContract();
        // Reject double-locking the same underlying NFT. For honest ERC721
        // contracts this can never be reached (helper already holds the
        // token), but it also closes the door on a malicious / quirky
        // ERC721 that re-enters lockNFT from inside its own
        // safeTransferFrom and would otherwise overwrite the _lockedBy
        // back-reference and confuse {rescueNFT}.
        if (_lockedBy[nftContract][tokenId] != 0) revert UnderlyingAlreadyLocked();

        lockId = nextLockId++;
        uint64 lockedAt = uint64(block.timestamp);
        uint64 unlockAt;
        unchecked {
            unlockAt = lockedAt + lockDuration;
        }
        if (unlockAt < lockedAt) revert InvalidLockDuration();

        _nftLocks[lockId] =
            NFTLock({nftContract: nftContract, tokenId: tokenId, lockedAt: lockedAt, unlockAt: unlockAt});
        _lockedBy[nftContract][tokenId] = lockId;

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        // Mint the receipt NFT to the locker. We use _mint (not _safeMint)
        // to avoid imposing an IERC721Receiver requirement on the caller —
        // this mirrors {unlockNFT} which also uses plain `transferFrom` to
        // return the underlying NFT, so non-receiver contracts can fully
        // participate in the lock/unlock lifecycle.
        _mint(msg.sender, lockId);

        emit NFTLocked(lockId, msg.sender, nftContract, tokenId, lockedAt, unlockAt);
    }

    /// @notice Release a previously locked NFT after its unlock time. The
    ///         caller must currently hold the receipt NFT.
    /// @param lockId The lock identifier returned by {lockNFT}.
    function unlockNFT(uint256 lockId) external {
        NFTLock memory lockInfo = _nftLocks[lockId];
        if (lockInfo.nftContract == address(0)) revert LockNotFound();
        if (msg.sender != _ownerOf(lockId)) revert NotLockOwner();
        if (block.timestamp < lockInfo.unlockAt) revert LockNotExpired();

        delete _nftLocks[lockId];
        delete _lockedBy[lockInfo.nftContract][lockInfo.tokenId];
        _burn(lockId);

        // Use plain transferFrom (not safeTransferFrom) so that receipt
        // holders that do not implement IERC721Receiver can still unlock.
        // The receipt itself is a standard ERC721, so it can already be moved
        // around with transferFrom; refusing to return the underlying via
        // safeTransferFrom would otherwise strand assets.
        IERC721(lockInfo.nftContract).transferFrom(address(this), msg.sender, lockInfo.tokenId);

        emit NFTUnlocked(lockId, msg.sender, lockInfo.nftContract, lockInfo.tokenId);
    }

    /// @notice Owner-only rescue for NFTs that were transferred to this
    ///         contract outside of {lockNFT} (e.g. accidental direct
    ///         `safeTransferFrom`). Cannot be used to pull out NFTs that
    ///         currently back an active lock receipt.
    /// @param nftContract The ERC721 contract.
    /// @param tokenId The token id to rescue.
    /// @param to Recipient of the rescued NFT.
    function rescueNFT(address nftContract, uint256 tokenId, address to) external onlyOwner {
        if (_lockedBy[nftContract][tokenId] != 0) revert UnderlyingStillLocked();
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
        emit NFTRescued(nftContract, tokenId, to);
    }

    /// @notice Whether the given lock id refers to an active lock record.
    ///         Returns false for ids that were never minted or have already
    ///         been released. Use this to disambiguate the "lock doesn't
    ///         exist" case from {getRemainingLockTime} returning 0.
    function lockExists(uint256 lockId) public view returns (bool) {
        return _nftLocks[lockId].nftContract != address(0);
    }

    /// @notice Return the full record for a given lock id. For ids that do
    ///         not correspond to an active lock, the returned struct is
    ///         zero-initialized (in particular `nftContract == address(0)`).
    function getNFTLock(uint256 lockId) external view returns (NFTLock memory) {
        return _nftLocks[lockId];
    }

    /// @notice Return the remaining seconds until a lock can be released.
    ///         Returns 0 both when the lock is already releasable and when
    ///         the given lock id does not exist — use {lockExists} to tell
    ///         the two cases apart.
    function getRemainingLockTime(uint256 lockId) external view returns (uint64 remaining) {
        NFTLock memory lockInfo = _nftLocks[lockId];
        if (block.timestamp >= lockInfo.unlockAt) {
            return 0;
        }
        remaining = lockInfo.unlockAt - uint64(block.timestamp);
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
