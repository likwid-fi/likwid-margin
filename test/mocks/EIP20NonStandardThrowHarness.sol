// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "./EIP20NonStandardInterface.sol";

// Note: the throw harness here always throws for errors, which is more realistic and useful
//       for JavaScript tests. For Solidity tests, use: EIP20NonStandardReturnHarness.
contract EIP20NonStandardThrowHarness is EIP20NonStandardInterface {
    uint256 private constant MAX_UINT256 = 2 ** 256 - 1;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowed;

    /*
    To support testing, we can specify addresses for which transferFrom should fail and return false.
    See `harnessSetFailTransferFromAddress`
    */
    mapping(address => bool) public failTransferFromAddresses;

    /*
    To support testing, we allow the contract to always fail `transfer`.
    */
    mapping(address => bool) public failTransferToAddresses;

    /*
    NOTE:
    The following variables are OPTIONAL vanities. One does not have to include them.
    They allow one to customise the token contract & in no way influences the core functionality.
    Some wallets/interfaces might not even bother to look at this information.
    */
    string public name; //fancy name: eg Simon Bucks
    uint8 public decimals; //How many decimals to show.
    string public symbol; //An identifier: eg SBX

    constructor(uint256 _initialAmount, string memory _tokenName, uint8 _decimalUnits, string memory _tokenSymbol) {
        balances[msg.sender] = _initialAmount; // Give the creator all initial tokens
        totalSupply = _initialAmount; // Update total supply
        name = _tokenName; // Set the name for display purposes
        decimals = _decimalUnits; // Amount of decimals for display purposes
        symbol = _tokenSymbol; // Set the symbol for display purposes
    }

    /**
     * @dev Specify `address, true` to cause transfers from address to fail.
     *      Once an address has been marked for failure it can be cleared by
     *      with `address, false`
     */
    function harnessSetFailTransferFromAddress(address _from, bool _fail) public {
        failTransferFromAddresses[_from] = _fail;
    }

    /**
     * @dev Specify `address, true` to cause transfers to address to fail.
     *      Once an address has been marked for failure it can be cleared by
     *      with `address, false`
     */
    function harnessSetFailTransferToAddress(address _to, bool _fail) public {
        failTransferToAddresses[_to] = _fail;
    }

    function harnessSetBalance(address _account, uint256 _amount) public {
        balances[_account] = _amount;
    }

    function transfer(address _to, uint256 _value) public override {
        require(balances[msg.sender] >= _value);

        // Added for testing purposes
        if (failTransferToAddresses[_to]) {
            revert();
        }

        balances[msg.sender] -= _value;
        balances[_to] += _value;
        emit Transfer(msg.sender, _to, _value);
    }

    function transferFrom(address _from, address _to, uint256 _value) public override {
        // Added for testing purposes
        if (_from == address(0)) {
            revert();
        }

        // Added for testing purposes
        if (failTransferFromAddresses[_from]) {
            revert();
        }

        uint256 _allowance = allowed[_from][msg.sender];
        require(balances[_from] >= _value && _allowance >= _value);
        balances[_to] += _value;
        balances[_from] -= _value;
        if (_allowance < MAX_UINT256) {
            allowed[_from][msg.sender] -= _value;
        }
        emit Transfer(_from, _to, _value);
    }

    function balanceOf(address _owner) public view override returns (uint256 balance) {
        return balances[_owner];
    }

    function approve(address _spender, uint256 _value) public override {
        allowed[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
    }

    function allowance(address _owner, address _spender) public view override returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }
}
