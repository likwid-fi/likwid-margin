using Helper as Helper;

methods {
    function _.transfer(address to, uint256 amount) external with (env e)
        => transferCVL(calledContract, e.msg.sender, to, amount) expect bool;
    function _.transferFrom(address from, address to, uint256 amount) external with (env e) 
        => transferFromCVL(calledContract, e.msg.sender, from, to, amount) expect bool;
    function _.balanceOf(address account) external => 
        tokenBalanceOf(calledContract, account) expect uint256;
    function _.allowance(address owner, address spender) external => 
        tokenAllowanceOf(calledContract, owner, spender) expect uint256;

    function Helper.fromCurrency(PoolManager.Currency) external returns (address) envfree;
    /// CurrencyLibrary transfer
    function CurrencyLibrary.transfer(PoolManager.Currency currency, address to, uint256 amount) internal with (env e) => currencyTransfer(calledContract, currency, to, amount);
}

definition NATIVE() returns address = 0;

/// CVL simple implementations of IERC20:
/// token => account => balance
ghost mapping(address => mapping(address => uint256)) balanceByToken;
/// token => owner => spender => allowance
ghost mapping(address => mapping(address => mapping(address => uint256))) allowanceByToken;

function currencyTransfer(address sender, PoolManager.Currency currency, address recipient, uint256 amount) {
    address token = Helper.fromCurrency(currency);
    if(token == NATIVE()) {
        mathint native_pre = nativeBalances[recipient];
            env ef;
            require ef.msg.value == amount;
            require ef.msg.sender == sender;
            Helper.callFallback(ef, recipient, amount);
        mathint native_post = nativeBalances[recipient];
        /// Sanity check for success
        assert native_post - native_pre == amount;
    } else {
        bool success = transferCVL(token, sender, recipient, amount);
        require success;
    }
}

function tokenBalanceOf(address token, address account) returns uint256 {
    if(token == 0) return nativeBalances[account];
    return balanceByToken[token][account];
}

function tokenAllowanceOf(address token, address account, address spender) returns uint256 {
    if(token == 0) return max_uint256;
    return allowanceByToken[token][account][spender];
}

function transferFromCVL(address token, address spender, address from, address to, uint256 amount) returns bool {
    require allowanceByToken[token][from][spender] >= amount;
    bool success = transferCVL(token, from, to, amount);
    if(success) {
        allowanceByToken[token][from][spender] = assert_uint256(allowanceByToken[token][from][spender] - amount);
    }
    return success;
}

function transferCVL(address token, address from, address to, uint256 amount) returns bool {
    require balanceByToken[token][from] >= amount;
    balanceByToken[token][from] = assert_uint256(balanceByToken[token][from] - amount);
    balanceByToken[token][to] = require_uint256(balanceByToken[token][to] + amount);  // We neglect overflows.
    return true;
}

function tokenAllowanceOf(address token, address account, address spender) returns uint256 {
    if(token == 0) return max_uint256;
    return allowanceByToken[token][account][spender];
}
