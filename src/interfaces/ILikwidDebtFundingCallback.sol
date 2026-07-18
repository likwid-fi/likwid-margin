// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title ILikwidDebtFundingCallback
/// @notice Optional just-in-time funding source for a debt market quote. Lets an underwriter
/// keep idle capital in yield strategies and deliver it only when a quote is filled.
interface ILikwidDebtFundingCallback {
    /// @notice Called by the debt market when a quote with this callback is being filled.
    /// The callback must transfer at least `amount` of `fundingToken` to msg.sender (the debt
    /// market) before returning; any shortfall is pulled from the underwriter's allowance instead.
    /// @dev Implementations MUST verify msg.sender is the trusted debt market and that quoteId
    /// belongs to their underwriter, since fills are triggered by third parties.
    /// @param quoteId The quote being filled
    /// @param fundingToken The ERC20 to deliver (the debt currency, or the wrapped native token
    /// when the debt currency is native)
    /// @param amount The required amount
    function likwidDebtMarketFunding(uint256 quoteId, address fundingToken, uint256 amount) external;
}
