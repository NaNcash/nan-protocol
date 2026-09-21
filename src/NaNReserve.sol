// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {NaNToken} from "./NaNToken.sol";
import {INFToken} from "./INFToken.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {MathLib} from "./libraries/MathLib.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

/// @title NaN Reserve
/// @notice Minimal pooled-reserve stablecoin inspired by the senior/junior economics of USM/FUM.
/// @dev NaN is the senior $1 claim. INF owns the residual reserve value and absorbs losses first.
///      The contract is intentionally ownerless and non-upgradeable.
contract NaNReserve is ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    error ZeroAmount();
    error ZeroAddress();
    error InvalidConfiguration();
    error DebtRatioTooHigh();
    error NoEquity();
    error NoDebt();
    error Slippage();
    error UnsupportedTransferFee();
    error InsolventFundingNotImplemented();

    enum Health {
        NoDebt,
        Healthy,
        Stressed,
        Insolvent
    }

    IERC20 public immutable collateral;
    IPriceOracle public immutable oracle;
    NaNToken public immutable nan;
    INFToken public immutable inf;

    /// @notice Maximum debt / reserve value during normal operation, in basis points.
    uint256 public immutable maxDebtRatioBps;
    uint256 public immutable mintFeeBps;
    uint256 public immutable redeemFeeBps;

    event Funded(address indexed caller, address indexed recipient, uint256 collateralIn, uint256 infOut);
    event Defunded(address indexed caller, address indexed recipient, uint256 infIn, uint256 collateralOut);
    event Minted(address indexed caller, address indexed recipient, uint256 collateralIn, uint256 nanOut, uint256 feeUsd);
    event Redeemed(address indexed caller, address indexed recipient, uint256 nanIn, uint256 collateralOut, uint256 feeUsd);

    constructor(
        IERC20 collateral_,
        IPriceOracle oracle_,
        uint256 maxDebtRatioBps_,
        uint256 mintFeeBps_,
        uint256 redeemFeeBps_
    ) {
        if (address(collateral_) == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        if (maxDebtRatioBps_ == 0 || maxDebtRatioBps_ >= BPS) revert InvalidConfiguration();
        if (mintFeeBps_ >= BPS || redeemFeeBps_ >= BPS) revert InvalidConfiguration();

        collateral = collateral_;
        oracle = oracle_;
        maxDebtRatioBps = maxDebtRatioBps_;
        mintFeeBps = mintFeeBps_;
        redeemFeeBps = redeemFeeBps_;

        nan = new NaNToken(address(this));
        inf = new INFToken(address(this));
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function collateralPriceUsd() public view returns (uint256) {
        return oracle.price();
    }

    function reserveCollateral() public view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    function reserveUsd() public view returns (uint256) {
        return _collateralToUsd(reserveCollateral(), collateralPriceUsd());
    }

    function debtUsd() public view returns (uint256) {
        return nan.totalSupply();
    }

    function equityUsd() public view returns (uint256) {
        uint256 reserve = reserveUsd();
        uint256 debt = debtUsd();
        return reserve > debt ? reserve - debt : 0;
    }

    /// @notice NaN liabilities divided by reserve value, in basis points. May exceed 10,000 if insolvent.
    function debtRatioBps() public view returns (uint256) {
        uint256 reserve = reserveUsd();
        uint256 debt = debtUsd();
        if (debt == 0) return 0;
        if (reserve == 0) return type(uint256).max;
        return MathLib.mulDivDown(debt, BPS, reserve);
    }

    /// @notice Reserve value divided by NaN liabilities, 1e18-scaled. Max uint when there is no debt.
    function collateralRatio() public view returns (uint256) {
        uint256 debt = debtUsd();
        if (debt == 0) return type(uint256).max;
        return MathLib.mulDivDown(reserveUsd(), WAD, debt);
    }

    function health() public view returns (Health) {
        uint256 debt = debtUsd();
        if (debt == 0) return Health.NoDebt;
        uint256 reserve = reserveUsd();
        if (reserve <= debt) return Health.Insolvent;
        if (_withinMaxDebtRatio(debt, reserve)) return Health.Healthy;
        return Health.Stressed;
    }

    /// @notice Residual NAV per INF, in USD with 18 decimals. Returns zero when reserve <= debt.
    function infPriceUsd() public view returns (uint256) {
        uint256 supply = inf.totalSupply();
        if (supply == 0) return WAD;
        uint256 equity = equityUsd();
        if (equity == 0) return 0;
        return MathLib.mulDivDown(equity, WAD, supply);
    }

    /// @notice Current NaN redemption price before the explicit redemption fee.
    /// @dev $1 when solvent; pro-rata reserve value when insolvent.
    function nanRedemptionPriceUsd() public view returns (uint256) {
        uint256 debt = debtUsd();
        if (debt == 0) return WAD;
        uint256 reserve = reserveUsd();
        if (reserve >= debt) return WAD;
        return MathLib.mulDivDown(reserve, WAD, debt);
    }

    /// @notice Maximum USD of residual reserve that INF holders may currently remove while preserving the max debt ratio.
    function maxDefundableUsd() public view returns (uint256) {
        uint256 reserve = reserveUsd();
        uint256 debt = debtUsd();
        if (debt == 0) return reserve;

        uint256 minReserve = MathLib.mulDivDown(debt, BPS, maxDebtRatioBps);
        if (reserve <= minReserve) return 0;
        return reserve - minReserve;
    }

    // -------------------------------------------------------------------------
    // State transitions
    // -------------------------------------------------------------------------

    /// @notice Add junior capital and mint INF at current residual NAV.
    /// @dev Initial INF starts at $1. Funding while insolvent is deliberately left for a recapitalisation module.
    function fund(uint256 collateralIn, uint256 minInfOut, address recipient)
        external
        nonReentrant
        returns (uint256 infOut)
    {
        if (collateralIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 price = collateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        uint256 debt = debtUsd();
        uint256 infSupply = inf.totalSupply();
        uint256 usdIn = _collateralToUsd(collateralIn, price);

        if (infSupply == 0) {
            if (debt != 0) revert InsolventFundingNotImplemented();
            infOut = usdIn; // bootstrap at $1 per INF
        } else {
            if (reserveBefore <= debt) revert InsolventFundingNotImplemented();
            uint256 equityBefore = reserveBefore - debt;
            infOut = MathLib.mulDivDown(usdIn, infSupply, equityBefore);
        }

        if (infOut == 0 || infOut < minInfOut) revert Slippage();
        _pullExact(collateralIn);
        inf.mint(recipient, infOut);

        emit Funded(msg.sender, recipient, collateralIn, infOut);
    }

    /// @notice Redeem INF for its proportional residual reserve value.
    /// @dev Reverts if the withdrawal would push debt/reserve above maxDebtRatioBps.
    function defund(uint256 infIn, uint256 minCollateralOut, address recipient)
        external
        nonReentrant
        returns (uint256 collateralOut)
    {
        if (infIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 price = collateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        uint256 debt = debtUsd();
        uint256 infSupply = inf.totalSupply();
        if (infSupply == 0 || reserveBefore <= debt) revert NoEquity();

        uint256 equityBefore = reserveBefore - debt;
        uint256 usdOut = MathLib.mulDivDown(infIn, equityBefore, infSupply);
        collateralOut = _usdToCollateral(usdOut, price);
        if (collateralOut == 0 || collateralOut < minCollateralOut) revert Slippage();

        uint256 actualUsdOut = _collateralToUsd(collateralOut, price);
        uint256 reserveAfter = reserveBefore - actualUsdOut;
        if (!_withinMaxDebtRatio(debt, reserveAfter)) revert DebtRatioTooHigh();

        inf.burn(msg.sender, infIn);
        address(collateral).safeTransfer(recipient, collateralOut);

        emit Defunded(msg.sender, recipient, infIn, collateralOut);
    }

    /// @notice Deposit wstETH and mint NaN at oracle value minus the explicit mint fee.
    /// @dev Minting is only permitted if the post-trade debt ratio remains under maxDebtRatioBps.
    function mint(uint256 collateralIn, uint256 minNanOut, address recipient)
        external
        nonReentrant
        returns (uint256 nanOut)
    {
        if (collateralIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 price = collateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        uint256 debtBefore = debtUsd();
        uint256 usdIn = _collateralToUsd(collateralIn, price);
        uint256 feeUsd = MathLib.mulDivDown(usdIn, mintFeeBps, BPS);
        nanOut = usdIn - feeUsd;

        if (nanOut == 0 || nanOut < minNanOut) revert Slippage();
        uint256 reserveAfter = reserveBefore + usdIn;
        uint256 debtAfter = debtBefore + nanOut;
        if (!_withinMaxDebtRatio(debtAfter, reserveAfter)) revert DebtRatioTooHigh();

        _pullExact(collateralIn);
        nan.mint(recipient, nanOut);

        emit Minted(msg.sender, recipient, collateralIn, nanOut, feeUsd);
    }

    /// @notice Burn NaN and redeem wstETH.
    /// @dev Solvent systems redeem at $1 minus fee. Insolvent systems redeem pro-rata with no fee,
    ///      preventing early redeemers from draining more than their share of the remaining reserve.
    function redeem(uint256 nanIn, uint256 minCollateralOut, address recipient)
        external
        nonReentrant
        returns (uint256 collateralOut)
    {
        if (nanIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 price = collateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        uint256 debtBefore = debtUsd();
        if (debtBefore == 0) revert NoDebt();

        uint256 redemptionPrice = reserveBefore >= debtBefore
            ? WAD
            : MathLib.mulDivDown(reserveBefore, WAD, debtBefore);
        uint256 grossUsdOut = MathLib.mulDivDown(nanIn, redemptionPrice, WAD);

        uint256 feeBps = reserveBefore > debtBefore ? redeemFeeBps : 0;
        uint256 feeUsd = MathLib.mulDivDown(grossUsdOut, feeBps, BPS);
        uint256 netUsdOut = grossUsdOut - feeUsd;
        collateralOut = _usdToCollateral(netUsdOut, price);

        if (collateralOut == 0 || collateralOut < minCollateralOut) revert Slippage();

        nan.burn(msg.sender, nanIn);
        address(collateral).safeTransfer(recipient, collateralOut);

        emit Redeemed(msg.sender, recipient, nanIn, collateralOut, feeUsd);
    }

    // -------------------------------------------------------------------------
    // Internal math
    // -------------------------------------------------------------------------

    function _collateralToUsd(uint256 collateralAmount, uint256 price) internal pure returns (uint256) {
        return MathLib.mulDivDown(collateralAmount, price, WAD);
    }

    function _usdToCollateral(uint256 usdAmount, uint256 price) internal pure returns (uint256) {
        return MathLib.mulDivDown(usdAmount, WAD, price);
    }

    function _withinMaxDebtRatio(uint256 debt, uint256 reserve) internal view returns (bool) {
        if (debt == 0) return true;
        if (reserve == 0) return false;
        return debt * BPS <= reserve * maxDebtRatioBps;
    }

    function _pullExact(uint256 amount) internal {
        uint256 beforeBalance = collateral.balanceOf(address(this));
        address(collateral).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateral.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnsupportedTransferFee();
    }
}
