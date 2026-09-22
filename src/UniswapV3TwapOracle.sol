// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

interface IUniswapV3PoolTwap {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Immutable wstETH/USD fallback using Uniswap v3 wstETH/WETH and WETH/USDC TWAPs.
/// @dev Treats one USDC as one USD. Both canonical pools must have sufficient current liquidity
///      and harmonic mean liquidity over the observation window, or the quote fails closed.
contract UniswapV3TwapOracle is IPriceOracle {
    error InvalidConfiguration();
    error InvalidPool();
    error InvalidObservation();
    error InsufficientLiquidity();
    error InvalidPrice();

    uint256 public constant WAD = 1e18;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q128 = 1 << 128;
    uint256 private constant USDC_TO_WAD = 1e12;

    address public immutable wstETH;
    address public immutable weth;
    address public immutable usdc;
    IUniswapV3Factory public immutable factory;
    IUniswapV3PoolTwap public immutable wstEthWethPool;
    IUniswapV3PoolTwap public immutable wethUsdcPool;
    uint32 public immutable twapWindow;
    uint128 public immutable minWstEthWethLiquidity;
    uint128 public immutable minWethUsdcLiquidity;

    constructor(
        address wstETH_,
        address weth_,
        address usdc_,
        IUniswapV3Factory factory_,
        IUniswapV3PoolTwap wstEthWethPool_,
        IUniswapV3PoolTwap wethUsdcPool_,
        uint32 twapWindow_,
        uint128 minWstEthWethLiquidity_,
        uint128 minWethUsdcLiquidity_
    ) {
        if (
            wstETH_ == address(0) || weth_ == address(0) || usdc_ == address(0) || address(factory_) == address(0)
                || address(wstEthWethPool_) == address(0) || address(wethUsdcPool_) == address(0) || wstETH_ == weth_
                || weth_ == usdc_ || wstETH_ == usdc_ || twapWindow_ < 30 minutes || twapWindow_ > 1 days
                || minWstEthWethLiquidity_ == 0 || minWethUsdcLiquidity_ == 0
        ) revert InvalidConfiguration();
        if (
            IERC20Metadata(wstETH_).decimals() != 18 || IERC20Metadata(weth_).decimals() != 18
                || IERC20Metadata(usdc_).decimals() != 6
        ) revert InvalidConfiguration();

        _validatePool(factory_, wstEthWethPool_, wstETH_, weth_);
        _validatePool(factory_, wethUsdcPool_, weth_, usdc_);

        wstETH = wstETH_;
        weth = weth_;
        usdc = usdc_;
        factory = factory_;
        wstEthWethPool = wstEthWethPool_;
        wethUsdcPool = wethUsdcPool_;
        twapWindow = twapWindow_;
        minWstEthWethLiquidity = minWstEthWethLiquidity_;
        minWethUsdcLiquidity = minWethUsdcLiquidity_;
    }

    /// @notice USD value of one wstETH, scaled to 1e18; reverts if either TWAP is unavailable.
    function price() external view returns (uint256 wstEthUsd) {
        int24 wstEthWethTick = _consult(wstEthWethPool, minWstEthWethLiquidity);
        int24 wethUsdcTick = _consult(wethUsdcPool, minWethUsdcLiquidity);

        uint256 wethAmount = _quoteAtTick(wstEthWethTick, WAD, wstETH, weth);
        uint256 usdcAmount = _quoteAtTick(wethUsdcTick, wethAmount, weth, usdc);
        if (usdcAmount == 0 || usdcAmount > type(uint256).max / USDC_TO_WAD) revert InvalidPrice();
        wstEthUsd = usdcAmount * USDC_TO_WAD;
    }

    function _consult(IUniswapV3PoolTwap pool, uint128 minimumLiquidity) internal view returns (int24 meanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;

        (int56[] memory ticks, uint160[] memory secondsPerLiquidity) = pool.observe(secondsAgos);
        if (ticks.length != 2 || secondsPerLiquidity.length != 2 || secondsPerLiquidity[1] <= secondsPerLiquidity[0]) {
            revert InvalidObservation();
        }

        uint256 liquidityDelta = uint256(secondsPerLiquidity[1]) - uint256(secondsPerLiquidity[0]);
        uint256 harmonicLiquidity = Math.mulDiv(uint256(twapWindow), Q128, liquidityDelta);
        if (harmonicLiquidity < minimumLiquidity || pool.liquidity() < minimumLiquidity) {
            revert InsufficientLiquidity();
        }

        int256 tickDelta = int256(ticks[1]) - int256(ticks[0]);
        int256 window = int256(uint256(twapWindow));
        int256 roundedTick = tickDelta / window;
        if (tickDelta < 0 && tickDelta % window != 0) --roundedTick;
        if (roundedTick < TickMath.MIN_TICK || roundedTick > TickMath.MAX_TICK) revert InvalidObservation();
        meanTick = SafeCast.toInt24(roundedTick);
    }

    function _quoteAtTick(int24 tick, uint256 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256)
    {
        uint256 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        // Two full-precision divisions avoid squaring the Q64.96 price into a 320-bit intermediate.
        // Round up on both legs so rounding never lowers the fallback redemption conversion price.
        if (baseToken < quoteToken) {
            uint256 scaledAmount = Math.mulDiv(baseAmount, sqrtPriceX96, Q96, Math.Rounding.Ceil);
            return Math.mulDiv(scaledAmount, sqrtPriceX96, Q96, Math.Rounding.Ceil);
        }
        uint256 intermediate = Math.mulDiv(baseAmount, Q96, sqrtPriceX96, Math.Rounding.Ceil);
        return Math.mulDiv(intermediate, Q96, sqrtPriceX96, Math.Rounding.Ceil);
    }

    function _validatePool(IUniswapV3Factory factory_, IUniswapV3PoolTwap pool, address tokenA, address tokenB)
        internal
        view
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (
            pool.factory() != address(factory_) || pool.token0() != token0 || pool.token1() != token1
                || factory_.getPool(token0, token1, pool.fee()) != address(pool)
        ) revert InvalidPool();
    }
}
