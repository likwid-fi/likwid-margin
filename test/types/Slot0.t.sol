// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Forge
import {Test} from "forge-std/Test.sol";
// Likwid Contracts
import {Slot0} from "../../src/types/Slot0.sol";

contract Slot0Test is Test {
    Slot0 private slot0;

    function setUp() public {
        slot0 = Slot0.wrap(0);
    }

    function testSetAndGetTotalSupply() public {
        uint128 totalSupply = 100 ether;
        slot0 = slot0.setTotalSupply(totalSupply);
        assertEq(slot0.totalSupply(), totalSupply);
    }

    function testSetAndGetLastUpdated() public {
        uint32 lastUpdated = 1711123225;
        slot0 = slot0.setLastUpdated(lastUpdated);
        assertEq(slot0.lastUpdated(), lastUpdated);
    }

    function testSetAndGetLpFee() public {
        uint24 lpFee = 3000; // 0.3%
        slot0 = slot0.setLpFee(lpFee);
        assertEq(slot0.lpFee(), lpFee);
    }

    function testSetAndGetProtocolFee() public {
        uint24 protocolFee = 1500; // 0.15%
        slot0 = slot0.setProtocolFee(protocolFee);
        assertEq(slot0.protocolFee(0), protocolFee);
    }

    function testSetAndGetMarginFee() public {
        uint24 marginFee = 15000; // 1.5%
        slot0 = slot0.setMarginFee(marginFee);
        assertEq(slot0.marginFee(), marginFee);

        marginFee = 1500; // 0.15%
        slot0 = slot0.setMarginFee(marginFee);
        assertEq(slot0.marginFee(), marginFee);

        marginFee = 0; // 0%
        slot0 = slot0.setMarginFee(marginFee);
        assertEq(slot0.marginFee(), marginFee);
    }

    function testSetAndGetInsuranceFundPercentage() public {
        uint8 insuranceFundPercentage = 10; // 10%
        slot0 = slot0.setInsuranceFundPercentage(insuranceFundPercentage);
        assertEq(slot0.insuranceFundPercentage(), insuranceFundPercentage);

        insuranceFundPercentage = 101; // 101%
        slot0 = slot0.setInsuranceFundPercentage(insuranceFundPercentage);
        assertEq(slot0.insuranceFundPercentage(), insuranceFundPercentage);
    }

    function testSetAndGetRateRange() public {
        uint8 low = 1; //1%
        uint8 high = 100; //100%
        uint16 rateRange = (uint16(low) << 8) | uint16(high);
        slot0 = slot0.setRateRange(rateRange);
        assertEq(slot0.rateRange(), rateRange);
        uint256 activeRangeLow = slot0.rateRange() >> 8;
        uint256 activeRangeHigh = slot0.rateRange() & 0x00FF;
        assertEq(activeRangeLow, low);
        assertEq(activeRangeHigh, high);

        low = 111; //111%
        high = 0; //0%
        rateRange = (uint16(low) << 8) | uint16(high);
        slot0 = slot0.setRateRange(rateRange);
        assertEq(slot0.rateRange(), rateRange);
        activeRangeLow = slot0.rateRange() >> 8;
        activeRangeHigh = slot0.rateRange() & 0x00FF;
        assertEq(activeRangeLow, low);
        assertEq(activeRangeHigh, high);
    }
}
