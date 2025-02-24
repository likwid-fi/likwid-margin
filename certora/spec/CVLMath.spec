/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Basic definitions                                                                                  
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

definition abs(mathint x) returns mathint = 
    x > 0 ? x : -x;

definition min(mathint x, mathint y) returns mathint =
    x > y ? y : x;

definition max(mathint x, mathint y) returns mathint =
    x > y ? x : y;

definition WAD() returns uint256 = 10^18;

definition RAY() returns uint256 = 10^27;

definition equalUpTo(mathint x, mathint y, uint256 err) returns bool = abs(x-y) <= err;

/// Returns whether y is equal to x up to error bound of 'err' (18 decs).
/// e.g. 10% relative error => err = 1e17
definition relativeErrorBound(mathint x, mathint y, mathint err) returns bool = 
    (x != 0 
    ? abs(x - y) * WAD() <= abs(x) * err 
    : abs(y) <= err);

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Division-pessimistic summaries (assumes no overflow)                                                                                 
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

function mulDivCVL_pessim(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) returns uint256 {
    if(rounding == Math.Rounding.Floor) {
        return mulDivDownCVL_pessim(x,y,denominator);
    } else if(rounding == Math.Rounding.Ceil) {
        return mulDivUpCVL_pessim(x,y,denominator);
    } else {
        /// We don't expect to reach other rounding cases.
        assert false;
    }
    return 0;
}

function divUpCVL_pessim(uint256 x, uint256 y) returns uint256 {
    assert y !=0, "divUp error: cannot divide by zero";
    return require_uint256((x + y - 1) / y);
}

function mulDivDownCVL_pessim(uint256 x, uint256 y, uint256 z) returns uint256 {
    assert z !=0, "mulDivDown error: cannot divide by zero";
    return require_uint256(x * y / z);
}

function mulDivUpCVL_pessim(uint256 x, uint256 y, uint256 z) returns uint256 {
    assert z !=0, "mulDivDown error: cannot divide by zero";
    return require_uint256((x * y + z - 1) / z);
}

function mulDivDownCVL_no_div_pessim(uint256 x, uint256 y, uint256 z) returns uint256 {
    uint256 res;
    assert z != 0, "mulDivDown error: cannot divide by zero";
    mathint xy = x * y;
    mathint fz = res * z;

    require xy >= fz;
    require fz + z > xy;
    return res;
}

function mulDivUpCVL_no_div_pessim(uint256 x, uint256 y, uint256 z) returns uint256 {
    uint256 res;
    assert z != 0, "mulDivUp error: cannot divide by zero";
    mathint xy = x * y;
    mathint fz = res * z;

    require xy >= fz;
    require fz + z > xy;
    if (xy == fz) {
        return res;
    }
    return require_uint256(res + 1);
}

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Division-optimistic summaries (assumes no overflow)                                                                        
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

function divUpCVL(uint256 x, uint256 y) returns uint256 {
    require y !=0;
    return require_uint256((x + y - 1) / y);
}

function mulDivDownCVL(uint256 x, uint256 y, uint256 z) returns uint256 {
    require z !=0;
    return require_uint256(x * y / z);
}

function mulDivUpCVL(uint256 x, uint256 y, uint256 z) returns uint256 {
    require z !=0;
    return require_uint256((x * y + z - 1) / z);
}

function mulDivDownCVL_no_div(uint256 x, uint256 y, uint256 z) returns uint256 {
    uint256 res;
    require z != 0;
    mathint xy = x * y;
    mathint fz = res * z;

    require xy >= fz;
    require fz + z > xy;
    return res;
}

function mulDivUpCVL_no_div(uint256 x, uint256 y, uint256 z) returns uint256 {
    uint256 res;
    require z != 0;
    mathint xy = x * y;
    mathint fz = res * z;

    require xy >= fz;
    require fz + z > xy;
    if (xy == fz) {
        return res;
    }
    return require_uint256(res + 1);
}

/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Misc functions                                                                             
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

/// Calculates average of two numbers without overflow.
function averageCVL(uint256 a, uint256 b) returns uint256 {
    if(a > b) {
        return assert_uint256(b + (a-b)/2);
    } else {
        return assert_uint256(a + (b-a)/2);
    }
}

/// Short-cut for calculating sqrt(x) that rounds-down.
function sqrtCVL(uint256 x) returns uint256 {
    uint256 sqrt;
    require sqrt*sqrt <= x && (sqrt + 1)*(sqrt + 1) > x;
    return sqrt;
}