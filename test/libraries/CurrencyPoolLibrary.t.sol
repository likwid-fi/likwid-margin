// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CurrencyPoolLibrary} from "../../src/libraries/CurrencyPoolLibrary.sol";
import {Currency} from "../../src/types/Currency.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MarginBalanceDelta} from "../../src/types/MarginBalanceDelta.sol";
import {MarginState} from "../../src/types/MarginState.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Mock Vault that implements IVault interface for testing
contract MockVault is IVault {
    mapping(uint256 => uint256) public balances;
    uint256 public nativeBalance;

    function mint(address to, uint256 id, uint256 amount) external {
        balances[id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(balances[id] >= amount, "Insufficient balance");
        balances[id] -= amount;
    }

    function take(Currency currency, address recipient, uint256 amount) external {
        // Mock implementation
    }

    function settle() external payable returns (uint256 paid) {
        nativeBalance += msg.value;
        return msg.value;
    }

    function settleFor(address recipient) external payable returns (uint256 paid) {
        nativeBalance += msg.value;
        return msg.value;
    }

    function clear(Currency currency, uint256 amount) external {
        // Mock implementation
    }

    function sync(Currency currency) external {
        // Mock implementation
    }

    // IVault interface functions
    function modifyLiquidity(PoolKey calldata, IVault.ModifyLiquidityParams calldata)
        external
        returns (BalanceDelta, int128)
    {
        return (BalanceDelta.wrap(0), 0);
    }

    function swap(PoolKey calldata, IVault.SwapParams calldata) external returns (BalanceDelta, uint24, uint256) {
        return (BalanceDelta.wrap(0), 0, 0);
    }

    function donate(PoolKey calldata, uint256, uint256) external returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function lend(PoolKey calldata, IVault.LendParams calldata) external returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function marginBalance(PoolKey calldata, MarginBalanceDelta calldata) external returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function initialize(PoolKey calldata) external {}

    // IExtsload interface functions
    function extsload(bytes32 slot) external view returns (bytes32) {
        return bytes32(0);
    }

    function extsload(bytes32 slot, uint256 count) external view returns (bytes32[] memory) {
        bytes32[] memory values = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            values[i] = bytes32(0);
        }
        return values;
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        bytes32[] memory values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = bytes32(0);
        }
        return values;
    }

    // IExttload interface functions
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exttload(bytes32[] calldata) external pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    // IERC6909Claims interface functions
    function allowance(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function isOperator(address, address) external pure returns (bool) {
        return false;
    }

    function setOperator(address, bool) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    // IMarginBase interface functions
    function marginState() external pure returns (MarginState) {
        return MarginState.wrap(0);
    }

    function setMarginState(MarginState) external {}

    function marginController() external pure returns (address) {
        return address(0);
    }
}

contract CurrencyPoolLibraryTest is Test {
    using CurrencyPoolLibrary for Currency;

    MockVault vault;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    address payer;
    address recipient;

    function setUp() public {
        vault = new MockVault();
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        payer = address(this);
        recipient = address(0x123);

        token0.mint(payer, 1000 ether);
        token1.mint(payer, 1000 ether);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);
    }

    function testSettleNativeCurrency() public {
        uint256 amount = 1 ether;
        Currency nativeCurrency = Currency.wrap(address(0));

        uint256 vaultBalanceBefore = address(vault).balance;

        // Settle native currency
        CurrencyPoolLibrary.settle(nativeCurrency, vault, payer, amount, false);

        assertEq(address(vault).balance - vaultBalanceBefore, amount, "Vault should receive native currency");
    }

    function testSettleERC20() public {
        uint256 amount = 100 ether;

        uint256 payerBalanceBefore = token0.balanceOf(payer);
        uint256 vaultBalanceBefore = token0.balanceOf(address(vault));

        // Approve and settle
        CurrencyPoolLibrary.settle(currency0, vault, payer, amount, false);

        assertEq(payerBalanceBefore - token0.balanceOf(payer), amount, "Payer should send tokens");
        assertEq(token0.balanceOf(address(vault)) - vaultBalanceBefore, amount, "Vault should receive tokens");
    }

    function testSettleZeroAmount() public {
        // Should not revert with zero amount
        CurrencyPoolLibrary.settle(currency0, vault, payer, 0, false);
    }

    function testSettleLargeAmount() public {
        uint256 amount = 1000 ether;

        uint256 payerBalanceBefore = token0.balanceOf(payer);

        CurrencyPoolLibrary.settle(currency0, vault, payer, amount, false);

        assertEq(payerBalanceBefore - token0.balanceOf(payer), amount, "Should handle large amounts");
    }

    function testSettleFromContract() public {
        uint256 amount = 100 ether;

        // Transfer tokens to this contract first
        token0.transfer(address(this), amount);

        uint256 contractBalanceBefore = token0.balanceOf(address(this));

        // Settle from this contract
        CurrencyPoolLibrary.settle(currency0, vault, address(this), amount, false);

        assertEq(contractBalanceBefore - token0.balanceOf(address(this)), amount, "Contract should send tokens");
    }

    function testTakeWithClaims() public {
        uint256 amount = 100 ether;
        uint256 currencyId = uint256(uint160(Currency.unwrap(currency0)));

        // Take with claims (mint) - this will call vault.mint
        CurrencyPoolLibrary.take(currency0, vault, recipient, amount, true);

        assertEq(vault.balances(currencyId), amount, "Vault should record the mint");
    }

    function testTakeWithoutClaims() public {
        uint256 amount = 100 ether;

        // This would require a more complex mock for full testing
        // For now, we just verify the function doesn't revert
        CurrencyPoolLibrary.take(currency0, vault, recipient, amount, false);
    }

    function testTakeZeroAmount() public {
        // Should not revert with zero amount
        CurrencyPoolLibrary.take(currency0, vault, recipient, 0, true);
    }
}
