// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// OpenZeppelin
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Likwid
import {IVault} from "../../src/interfaces/IVault.sol";
import {IMarginPositionManager} from "../../src/interfaces/IMarginPositionManager.sol";
import {MarginPosition} from "../../src/libraries/MarginPosition.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";

/// @dev Extra getters on LikwidMarginPosition that are not declared in IMarginPositionManager
///      but exist as public state (BasePositionManager.poolKeys).
interface IMarginPositionExtra {
    function poolKeys(PoolId poolId)
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, uint24 marginFee);
}

/// @title LikwidMarginRouter
/// @notice A "mapping NFT" that custodies LikwidMarginPosition NFTs and acts as the single
///         user-facing entry point for margin operations.
///
/// Design
/// ------
/// * The router is an {ERC721Enumerable}. Each router token shares the SAME id as the underlying
///   LikwidMarginPosition token it wraps, so enumeration (`tokensOfOwner`) maps 1:1 to positions.
/// * The real position NFT is held by this contract. Because LikwidMarginPosition authorizes by
///   strict `ownerOf` equality (no operator/approval path), only this router can operate a wrapped
///   position — users cannot bypass it. The router re-checks router-NFT ownership before forwarding.
/// * LikwidMarginPosition settles every flow against `msg.sender` (here: the router). So the router
///   intermediates funds: it pulls the caller's input currency in, forwards the call, then sweeps all
///   currency0/currency1/native balances back to the caller. "Over-pull + sweep-all-back" makes the
///   exact internal amounts irrelevant and prevents trapped funds.
/// * The underlying NFT can never be burned (the manager has no burn — a contract-size cut). But once a
///   position is fully settled (empty: no debt, no margin), its mapping NFT is burned to clean up the
///   owner's enumeration / {positionOf}; the underlying then lingers here as a harmless empty husk.
///   repay/close auto-burn when they leave the position empty; {burn} cleans up externally-emptied ones.
///
/// Approvals the caller must set up
/// --------------------------------
/// * ERC20 input: approve THIS router for the input token (router → manager approval is handled here).
/// * Native input: send it as `msg.value`.
/// * `wrap`: approve THIS router on the LikwidMarginPosition NFT (it pulls the position in).
///
/// Caution: ERC721-approving, or setting an operator on, a mapping NFT grants that party FULL control of
/// the position — including `unwrap`-ing the underlying to an arbitrary address. Approve only trusted parties.
///
/// @dev Production-grade fund-routing code (despite living under test/utils). It has fund-flow tests and an
///      internal review, but obtain a professional audit — and pin the floating pragma — before any mainnet use.
contract LikwidMarginRouter is ERC721Enumerable, IERC721Receiver, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    IVault public immutable vault;
    IMarginPositionManager public immutable manager;

    /// @notice Pool + direction of a wrapped position. Cached at wrap/create time so the `_update`
    ///         hook can maintain {positionOf} on every mint/transfer/burn without re-reading state.
    struct PositionKey {
        PoolId poolId;
        bool marginForOne;
    }

    /// @notice Cached (poolId, marginForOne) for each wrapped tokenId.
    mapping(uint256 tokenId => PositionKey key) public keyOf;

    /// @notice O(1) index of an owner's self-established wrapped position per (pool, direction).
    /// @dev Set only when an owner establishes a position for themselves (self {wrap}/{margin}); cleared in
    ///      {_update} on transfer-out/burn. Transferred-in / created-for-other positions are deliberately
    ///      NOT indexed, so {margin} never auto-merges into a position the owner didn't vet. May still point
    ///      to an empty (closed/liquidated) position, so {margin}/{burn} re-check {_isEmpty}.
    mapping(address owner => mapping(PoolId poolId => mapping(bool marginForOne => uint256 tokenId))) public positionOf;

    /// @notice Emitted when a position becomes custodied and a mapping NFT is minted (via {wrap} or {margin}).
    event Wrapped(address indexed owner, uint256 indexed tokenId);
    /// @notice Emitted when a mapping NFT is burned and the underlying position is returned.
    event Unwrapped(address indexed owner, uint256 indexed tokenId, address indexed to);
    /// @notice Emitted when an empty (fully-settled) position's mapping NFT is burned.
    event Burned(address indexed owner, uint256 indexed tokenId);

    error NotAuthorized();
    /// @notice The vault has no margin controller set; `manager` would be the zero address.
    error ControllerUnset();
    /// @notice {burn} was called on a position that still has debt or margin.
    error PositionNotEmpty();

    constructor(IVault _vault) ERC721("Likwid Margin Position Router", "LMPR") {
        vault = _vault;
        manager = IMarginPositionManager(_vault.marginController());
        // `manager` is immutable, so a vault without a controller would brick the router silently.
        if (address(manager) == address(0)) revert ControllerUnset();
    }

    // ******************** ENUMERATION ********************

    /// @notice List every wrapped position tokenId owned by `owner`.
    /// @dev O(balanceOf(owner)) thanks to the underlying ERC721Enumerable index. May include empty husks
    ///      (e.g. a liquidated position not yet {burn}ed); filter by debt/margin for active positions only.
    function tokensOfOwner(address owner) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(owner);
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    // ******************** WRAP / UNWRAP ********************

    /// @notice Pull an existing position NFT into the router and mint the matching mapping NFT.
    /// @dev Caller must have approved this router on the LikwidMarginPosition NFT.
    /// @param positionTokenId The LikwidMarginPosition tokenId to wrap
    /// @param to Recipient of the mapping NFT (0 → caller)
    function wrap(uint256 positionTokenId, address to) external nonReentrant {
        IERC721(address(manager)).safeTransferFrom(msg.sender, address(this), positionTokenId);
        PoolId poolId = manager.poolIds(positionTokenId);
        bool marginForOne = manager.getPositionState(positionTokenId).marginForOne;
        keyOf[positionTokenId] = PositionKey({poolId: poolId, marginForOne: marginForOne});
        address mintTo = to == address(0) ? msg.sender : to;
        _mint(mintTo, positionTokenId);
        // Only index when wrapping a position into one's own custody: a wrap-for-other could be an aged /
        // distressed position the recipient never vetted, so it must not become an auto-merge target.
        if (mintTo == msg.sender) positionOf[mintTo][poolId][marginForOne] = positionTokenId;
        emit Wrapped(mintTo, positionTokenId);
    }

    /// @notice Burn the mapping NFT and return the underlying position NFT to `to`.
    /// @dev Callable by the mapping NFT's owner OR an approved party/operator (standard ERC721 auth), who may
    ///      send the underlying to any `to` — so an approval grants withdrawal rights (see contract caution).
    /// @param tokenId The wrapped position tokenId
    /// @param to Recipient of the underlying position NFT (0 → caller)
    function unwrap(uint256 tokenId, address to) external nonReentrant {
        _checkAuth(tokenId);
        address sendTo = to == address(0) ? msg.sender : to;
        _burn(tokenId);
        IERC721(address(manager)).safeTransferFrom(address(this), sendTo, tokenId);
        emit Unwrapped(msg.sender, tokenId, sendTo);
    }

    /// @notice Burn the mapping NFT of a fully-settled (empty) position to clean up enumeration.
    /// @dev The underlying NFT can't be burned (the manager has no burn), so it stays custodied here as a
    ///      harmless empty husk. For positions emptied outside the router (e.g. liquidation); repay/close
    ///      auto-burn when they leave the position empty. Reverts if the position still has debt or margin.
    ///      Irreversible: once burned, the empty husk can never be unwrapped or re-wrapped (the router owns
    ///      it and no mapping NFT exists for it). Safe because the position holds nothing of value.
    function burn(uint256 tokenId) external nonReentrant {
        _checkAuth(tokenId);
        if (!_isEmpty(tokenId)) revert PositionNotEmpty();
        _doBurn(tokenId);
    }

    // ******************** MARGIN OPERATIONS ********************

    /// @notice Open a new position or add to the caller's existing one in this pool — auto-detected.
    /// @dev O(1) lookup via {positionOf}: if the caller already has a non-empty position (any debt or
    ///      margin left — see {_isEmpty}) in the same pool (`key`) and direction (`params.marginForOne`),
    ///      margin is added to it (underlying `margin`); otherwise a new position is created (underlying
    ///      `addMargin`), custodied here, and a mapping NFT is minted to `recipient`. The {positionOf} slot
    ///      is keyed by the caller, so a hit already implies ownership — no extra auth check needed.
    /// @param key The pool key
    /// @param params Margin params; `recipient` is only used on create
    /// @param recipient Recipient of the mapping NFT on create (0 → caller)
    /// @return positionId The created or updated position tokenId
    /// @return borrowAmount The borrow amount
    /// @return swapFeeAmount The swap fee amount
    function margin(PoolKey calldata key, IMarginPositionManager.CreateParams calldata params, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 positionId, uint256 borrowAmount, uint256 swapFeeAmount)
    {
        PoolId poolId = key.toId();
        Currency marginCurrency = params.marginForOne ? key.currency1 : key.currency0;
        _pull(marginCurrency, params.marginAmount);
        _approveManager(marginCurrency, params.marginAmount);
        uint256 value = _value(marginCurrency);

        uint256 existing = positionOf[msg.sender][poolId][params.marginForOne];
        if (existing != 0 && !_isEmpty(existing)) {
            // ---- add margin to the caller's existing position ----
            (borrowAmount, swapFeeAmount) = manager.margin{value: value}(
                IMarginPositionManager.MarginParams({
                    tokenId: existing,
                    leverage: params.leverage,
                    marginAmount: params.marginAmount,
                    borrowAmount: params.borrowAmount,
                    borrowAmountMax: params.borrowAmountMax,
                    deadline: params.deadline
                })
            );
            positionId = existing;
        } else {
            // ---- create a new position, custodied here ----
            (positionId, borrowAmount, swapFeeAmount) = manager.addMargin{value: value}(
                key,
                IMarginPositionManager.CreateParams({
                    marginForOne: params.marginForOne,
                    leverage: params.leverage,
                    marginAmount: params.marginAmount,
                    borrowAmount: params.borrowAmount,
                    borrowAmountMax: params.borrowAmountMax,
                    recipient: address(this),
                    deadline: params.deadline
                })
            );
            keyOf[positionId] = PositionKey({poolId: poolId, marginForOne: params.marginForOne});
            address mintTo = recipient == address(0) ? msg.sender : recipient;
            _mint(mintTo, positionId);
            // Index only a position created for oneself; a create-for-other is not an auto-merge target.
            if (mintTo == msg.sender) positionOf[mintTo][poolId][params.marginForOne] = positionId;
            emit Wrapped(mintTo, positionId);
        }

        _sweep(key.currency0, key.currency1, msg.sender);
    }

    /// @notice Repay debt on a wrapped position. Released margin is swept back to the caller.
    function repay(uint256 tokenId, uint256 repayAmount, uint256 deadline) external payable nonReentrant {
        _checkAuth(tokenId);
        (Currency c0, Currency c1) = _poolCurrencies(tokenId);
        // debt/borrow currency is the opposite side of the margin currency
        Currency borrowCurrency = _marginForOne(tokenId) ? c0 : c1;

        _pull(borrowCurrency, repayAmount);
        _approveManager(borrowCurrency, repayAmount);
        manager.repay{value: _value(borrowCurrency)}(tokenId, repayAmount, deadline);

        _sweep(c0, c1, msg.sender);
        _burnIfEmpty(tokenId);
    }

    /// @notice Close (part of) a wrapped position. Proceeds are swept back to the caller.
    function close(uint256 tokenId, uint24 closeMillionth, uint256 closeAmountMin, uint256 deadline)
        external
        nonReentrant
    {
        _checkAuth(tokenId);
        (Currency c0, Currency c1) = _poolCurrencies(tokenId);
        manager.close(tokenId, closeMillionth, closeAmountMin, deadline);
        _sweep(c0, c1, msg.sender);
        _burnIfEmpty(tokenId);
    }

    /// @notice Modify a wrapped position's collateral. Positive `changeAmount` adds (caller pays),
    ///         negative withdraws (swept back to caller).
    function modify(uint256 tokenId, int128 changeAmount, uint256 deadline) external payable nonReentrant {
        _checkAuth(tokenId);
        (Currency c0, Currency c1) = _poolCurrencies(tokenId);

        if (changeAmount > 0) {
            Currency marginCurrency = _marginForOne(tokenId) ? c1 : c0;
            uint256 amount = uint256(uint128(changeAmount));
            _pull(marginCurrency, amount);
            _approveManager(marginCurrency, amount);
            manager.modify{value: _value(marginCurrency)}(tokenId, changeAmount, deadline);
        } else {
            manager.modify(tokenId, changeAmount, deadline);
        }

        _sweep(c0, c1, msg.sender);
    }

    // ******************** INTERNAL: AUTH & FUND ROUTING ********************

    function _checkAuth(uint256 tokenId) internal view {
        address owner = _requireOwned(tokenId);
        if (!_isAuthorized(owner, msg.sender, tokenId)) revert NotAuthorized();
    }

    function _poolCurrencies(uint256 tokenId) internal view returns (Currency c0, Currency c1) {
        PoolId poolId = manager.poolIds(tokenId);
        (c0, c1,,) = IMarginPositionExtra(address(manager)).poolKeys(poolId);
    }

    /// @dev A position is empty once fully settled: no debt and no margin (own or leveraged) left to
    ///      retrieve. Strict (all three zero) so dust value is never burned away.
    function _isEmpty(uint256 tokenId) internal view returns (bool) {
        MarginPosition.State memory s = manager.getPositionState(tokenId);
        return s.debtAmount == 0 && s.marginAmount == 0 && s.marginTotal == 0;
    }

    function _burnIfEmpty(uint256 tokenId) internal {
        if (_isEmpty(tokenId)) _doBurn(tokenId);
    }

    function _doBurn(uint256 tokenId) internal {
        address owner = _ownerOf(tokenId);
        _burn(tokenId); // clears positionOf / keyOf via _update
        emit Burned(owner, tokenId);
    }

    /// @dev Clear the sender's index slot on transfer-out / burn, and drop keyOf on burn. Crucially it does
    ///      NOT auto-index on transfer-in: {positionOf} only tracks positions an owner established for
    ///      themselves (self {wrap}/{margin}), so a transferred-in position — which could be distressed or
    ///      liquidatable — is never silently merged into by {margin}. Such a position stays fully
    ///      manageable by tokenId (repay/close/modify/unwrap/burn).
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0)) {
            PositionKey memory k = keyOf[tokenId];
            if (positionOf[from][k.poolId][k.marginForOne] == tokenId) {
                delete positionOf[from][k.poolId][k.marginForOne];
            }
        }
        if (to == address(0)) {
            delete keyOf[tokenId];
        }
    }

    function _marginForOne(uint256 tokenId) internal view returns (bool) {
        return manager.getPositionState(tokenId).marginForOne;
    }

    /// @dev Native input is already held via msg.value; ERC20 input is pulled from the caller.
    function _pull(Currency currency, uint256 amount) internal {
        if (amount == 0 || currency.isAddressZero()) return;
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev settle() does `transferFrom(router, vault)` from the manager's context, so the manager
    ///      (LikwidMarginPosition) is the spender that needs the allowance. Max approval is acceptable: the
    ///      router holds no tokens between calls, so there is nothing for the (trusted) manager to over-pull.
    function _approveManager(Currency currency, uint256 amount) internal {
        if (amount == 0 || currency.isAddressZero()) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), address(manager)) < amount) {
            token.forceApprove(address(manager), type(uint256).max);
        }
    }

    /// @dev How much native value to forward to the manager call.
    function _value(Currency inputCurrency) internal view returns (uint256) {
        return inputCurrency.isAddressZero() ? msg.value : 0;
    }

    /// @dev Sweep all proceeds/refunds the router received back to `to`. The router holds no funds
    ///      between calls, so sweeping the full balance is safe and captures every flow. Corollary:
    ///      tokens/native sent directly to the router are claimable by the next caller — never park
    ///      funds here.
    function _sweep(Currency c0, Currency c1, address to) internal {
        uint256 b0 = c0.balanceOfSelf();
        if (b0 > 0) c0.transfer(to, b0);
        uint256 b1 = c1.balanceOfSelf();
        if (b1 > 0) c1.transfer(to, b1);
        // covers stray native if neither side is the native currency
        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(to, nativeBal);
    }

    // ******************** RECEIVE HOOKS ********************

    /// @dev Accept the manager's position NFT only when this router itself initiated the transfer (i.e. from
    ///      within {wrap}, so `operator == address(this)`). This rejects a user directly safeTransferring an
    ///      underlying position in — which would otherwise be received with NO mapping NFT minted and get
    ///      permanently stuck (unoperable through the router, yet owned by the router on the manager).
    ///      NB: a plain (non-safe) `transferFrom` has no receiver hook and cannot be intercepted; sending an
    ///      underlying position that way is an unrecoverable user error, like sending any NFT to a contract.
    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(manager) || operator != address(this)) revert NotAuthorized();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @dev Receive native refunds/proceeds forwarded by the manager/vault during operations.
    receive() external payable {}
}
