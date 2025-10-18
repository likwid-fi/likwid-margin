// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeLibrary} from "../../src/libraries/ProtocolFeeLibrary.sol";
import {FeeTypes} from "../../src/types/FeeTypes.sol";

contract ProtocolFeeLibraryTest is Test {
    using ProtocolFeeLibrary for uint24;

    function testGetProtocolFees() public pure {
        uint24 fees = 0x140A05; // 20, 10, 5

        assertEq(fees.getProtocolInterestFee(), 20, "Interest fee should be 20");
        assertEq(fees.getProtocolMarginFee(), 10, "Margin fee should be 10");
        assertEq(fees.getProtocolSwapFee(), 5, "Swap fee should be 5");
    }

    function testIsValidProtocolFee() public pure {
        uint24 validFees = 0xC8C8C8; // 200, 200, 200
        assertTrue(validFees.isValidProtocolFee(), "Should be valid");

        uint24 invalidSwapFee = 0xC8C8C9; // 200, 200, 201
        assertFalse(invalidSwapFee.isValidProtocolFee(), "Should be invalid because of swap fee");

        uint24 invalidMarginFee = 0xC8C9C8; // 200, 201, 200
        assertFalse(invalidMarginFee.isValidProtocolFee(), "Should be invalid because of margin fee");

        uint24 invalidInterestFee = 0xC9C8C8; // 201, 200, 200
        assertFalse(invalidInterestFee.isValidProtocolFee(), "Should be invalid because of interest fee");
    }

    function testGetProtocolFee() public pure {
        uint24 fees = 0x140A05; // 20, 10, 5

        assertEq(fees.getProtocolFee(FeeTypes.INTERESTS), 20, "Interest fee should be 20");
        assertEq(fees.getProtocolFee(FeeTypes.MARGIN), 10, "Margin fee should be 10");
        assertEq(fees.getProtocolFee(FeeTypes.SWAP), 5, "Swap fee should be 5");
    }

    function testSetProtocolFee() public pure {
        uint24 fees = 0;

        fees = fees.setProtocolFee(FeeTypes.SWAP, 5);
        assertEq(fees, 0x05, "Swap fee should be set to 5");

        fees = fees.setProtocolFee(FeeTypes.MARGIN, 10);
        assertEq(fees, 0x0A05, "Margin fee should be set to 10");

        fees = fees.setProtocolFee(FeeTypes.INTERESTS, 20);
        assertEq(fees, 0x140A05, "Interest fee should be set to 20");
    }

    function setProtocolFee(uint24 fees, FeeTypes feeType, uint8 newFee) public pure returns (uint24) {
        return fees.setProtocolFee(feeType, newFee);
    }

    function testSetProtocolFee_revert() public {
        uint24 fees = 0;
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeLibrary.InvalidProtocolFee.selector, uint8(201)));
        this.setProtocolFee(fees, FeeTypes.SWAP, 201);
    }

    function testSplitFee() public pure {
        uint24 fees = 0;

        // 50% protocol fee for swap
        fees = fees.setProtocolFee(FeeTypes.SWAP, 100);

        uint256 totalFee = 1000;
        (uint256 protocolFee, uint256 remainingFee) = fees.splitFee(FeeTypes.SWAP, totalFee);

        assertEq(protocolFee, 500, "Protocol fee should be 500");
        assertEq(remainingFee, 500, "Remaining fee should be 500");
    }

    function testSplitFee_zero() public pure {
        uint24 fees = 0;

        uint256 totalFee = 1000;
        (uint256 protocolFee, uint256 remainingFee) = fees.splitFee(FeeTypes.SWAP, totalFee);

        assertEq(protocolFee, 0, "Protocol fee should be 0");
        assertEq(remainingFee, 1000, "Remaining fee should be 1000");
    }
}
