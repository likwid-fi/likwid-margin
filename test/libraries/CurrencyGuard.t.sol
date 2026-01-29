// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurrencyGuard} from "../../src/libraries/CurrencyGuard.sol";
import {Currency} from "../../src/types/Currency.sol";

contract CurrencyGuardTest is Test {
    using CurrencyGuard for Currency;

    Currency internal currency0;
    Currency internal currency1;
    address internal target;

    function setUp() public {
        currency0 = Currency.wrap(address(0x123));
        currency1 = Currency.wrap(address(0x456));
        target = address(0x789);
    }

    function testCurrencyDeltaSlot() public pure {
        Currency currency = Currency.wrap(address(0x123));
        address targetAddr = address(0x456);

        bytes32 slot = CurrencyGuard._currencyDeltaSlot(currency, targetAddr);
        bytes32 expectedSlot = keccak256(abi.encode(currency, targetAddr, CurrencyGuard.CURRENCY_DELTA));

        assertEq(slot, expectedSlot, "Currency delta slot should match expected hash");
    }

    function testCurrencyDeltaSlotDifferentInputs() public pure {
        Currency testCurrency1 = Currency.wrap(address(0x123));
        Currency testCurrency2 = Currency.wrap(address(0x456));
        address target1 = address(0x789);
        address target2 = address(0xABC);

        bytes32 slot1 = CurrencyGuard._currencyDeltaSlot(testCurrency1, target1);
        bytes32 slot2 = CurrencyGuard._currencyDeltaSlot(testCurrency1, target2);
        bytes32 slot3 = CurrencyGuard._currencyDeltaSlot(testCurrency2, target1);

        assertNotEq(slot1, slot2, "Different targets should produce different slots");
        assertNotEq(slot1, slot3, "Different currencies should produce different slots");
    }

    function testAppendDeltaPositive() public {
        Currency currency = Currency.wrap(address(0x123));
        address targetAddr = address(this);

        // First append
        (int256 previous, int256 current) = CurrencyGuard.appendDelta(currency, targetAddr, 100);
        assertEq(previous, 0, "Previous should be 0 for first append");
        assertEq(current, 100, "Current should be 100 after first append");

        // Second append
        (previous, current) = CurrencyGuard.appendDelta(currency, targetAddr, 50);
        assertEq(previous, 100, "Previous should be 100");
        assertEq(current, 150, "Current should be 150 after second append");
    }

    function testAppendDeltaNegative() public {
        Currency currency = Currency.wrap(address(0x123));
        address targetAddr = address(this);

        // First append positive
        CurrencyGuard.appendDelta(currency, targetAddr, 100);

        // Then append negative
        (int256 previous, int256 current) = CurrencyGuard.appendDelta(currency, targetAddr, -30);
        assertEq(previous, 100, "Previous should be 100");
        assertEq(current, 70, "Current should be 70 after negative append");
    }

    function testCurrentDelta() public {
        Currency currency = Currency.wrap(address(0x123));
        address targetAddr = address(this);

        // Initially should be 0
        int256 delta = CurrencyGuard.currentDelta(currency, targetAddr);
        assertEq(delta, 0, "Initial delta should be 0");

        // After appending
        CurrencyGuard.appendDelta(currency, targetAddr, 100);
        delta = CurrencyGuard.currentDelta(currency, targetAddr);
        assertEq(delta, 100, "Delta should be 100 after append");
    }

    function testCurrentDeltaDifferentTargets() public {
        Currency currency = Currency.wrap(address(0x123));
        address target1 = address(0x111);
        address target2 = address(0x222);

        CurrencyGuard.appendDelta(currency, target1, 100);
        CurrencyGuard.appendDelta(currency, target2, 200);

        assertEq(CurrencyGuard.currentDelta(currency, target1), 100, "Target1 delta should be 100");
        assertEq(CurrencyGuard.currentDelta(currency, target2), 200, "Target2 delta should be 200");
    }

    function testCurrentDeltaDifferentCurrencies() public {
        Currency testCurrency1 = Currency.wrap(address(0x123));
        Currency testCurrency2 = Currency.wrap(address(0x456));
        address targetAddr = address(this);

        CurrencyGuard.appendDelta(testCurrency1, targetAddr, 100);
        CurrencyGuard.appendDelta(testCurrency2, targetAddr, 200);

        assertEq(CurrencyGuard.currentDelta(testCurrency1, targetAddr), 100, "Currency1 delta should be 100");
        assertEq(CurrencyGuard.currentDelta(testCurrency2, targetAddr), 200, "Currency2 delta should be 200");
    }

    function testAppendDeltaZero() public {
        Currency currency = Currency.wrap(address(0x123));
        address targetAddr = address(this);

        CurrencyGuard.appendDelta(currency, targetAddr, 100);
        (int256 previous, int256 current) = CurrencyGuard.appendDelta(currency, targetAddr, 0);

        assertEq(previous, 100, "Previous should be 100");
        assertEq(current, 100, "Current should remain 100 with zero delta");
    }

    function testAppendDeltaLargeValues() public {
        Currency currency = Currency.wrap(address(0x123));
        address targetAddr = address(this);

        int128 largeValue = type(int128).max / 2;
        (int256 previous, int256 current) = CurrencyGuard.appendDelta(currency, targetAddr, largeValue);

        assertEq(previous, 0, "Previous should be 0");
        assertEq(current, int256(largeValue), "Current should be large value");
    }

    function testAppendDeltaNegativeLarge() public {
        Currency currency = Currency.wrap(address(0x123));
        address targetAddr = address(this);

        int128 largePositive = type(int128).max / 2;
        int128 largeNegative = -type(int128).max / 4;

        CurrencyGuard.appendDelta(currency, targetAddr, largePositive);
        (int256 previous, int256 current) = CurrencyGuard.appendDelta(currency, targetAddr, largeNegative);

        assertEq(previous, int256(largePositive), "Previous should be large positive");
        assertEq(current, int256(largePositive) + int256(largeNegative), "Current should be sum");
    }
}
