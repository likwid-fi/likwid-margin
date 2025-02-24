import "./CVLMath.spec";
/*
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Summarization of Open-Zeppelin Math library (optimistic, requires denominator is non-zero)                                                                                  
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
*/

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator, Math.Rounding rounding) internal returns (uint256) =>
        mulDivCVL(x,y,denominator,rounding);

    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256) =>
        mulDivDownCVL(x,y,denominator);

    function Math.average(uint256 a, uint256 b) internal returns (uint256) => averageCVL(a,b);

    function Math.sqrt(uint256 a) internal returns (uint256) => sqrtCVL(a);
}