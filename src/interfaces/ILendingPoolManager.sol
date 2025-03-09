// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IERC6909Accrues} from "../interfaces/external/IERC6909Accrues.sol";

interface ILendingPoolManager is IERC6909Accrues {}
