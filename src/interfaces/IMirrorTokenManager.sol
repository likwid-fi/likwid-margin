// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC6909Claims} from "./external/IERC6909Claims.sol";

interface IMirrorTokenManager is IERC6909Claims {
    function mint(uint256 id, uint256 amount) external;

    function mintInStatus(address receiver, uint256 id, uint256 amount) external;

    function burn(uint256 id, uint256 amount) external;

    function burn(address lendingPool, uint256 id, uint256 amount)
        external
        returns (uint256 pairAmount, uint256 lendingAmount);
}
