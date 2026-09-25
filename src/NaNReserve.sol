// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IReserveOracle} from "./interfaces/IReserveOracle.sol";
import {NaNToken} from "./NaNToken.sol";
import {INFToken} from "./INFToken.sol";

/// @title NaN Reserve
/// @notice Minimal pooled-reserve stablecoin inspired by the senior/junior economics of USM/FUM.
/// @dev NaN is the senior $1 claim. INF owns the residual reserve value and absorbs losses first.
///      The contract is intentionally ownerless and non-upgradeable.
contract NaNReserve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;

    error ZeroAmount();
    error ZeroAddress();
    error InvalidConfiguration();
    error InvalidPrice();
    error UnsupportedCollateralDecimals();
    error DebtRatioTooHigh();
    error NoEquity();
    error NoDebt();
    error NoJuniorCapital();
    error Slippage();
    error UnsupportedTransferFee();
    error RecapitalizationRequired();
    error NotInsolvent();
    error InsufficientRecapitalization();

    enum Health {
        NoDebt,
        Healthy,
        Stressed,
        Insolvent
    }

    IERC20 public immutable collateral;
    IReserveOracle public immutable oracle;
    NaNToken public immutable nan;
    /// @notice Active junior token. A recapitalization retires the old series and replaces this address.
    INFToken public inf;
    uint256 public juniorSeries;

    /// @notice Maximum debt / reserve value during normal operation, in basis points.
    uint256 public immutable maxDebtRatioBps;
    uint256 public immutable mintFeeBps;
    uint256 public immutable redeemFeeBps;

    event Funded(address indexed caller, address indexed recipient, uint256 collateralIn, uint256 infOut);
    event Defunded(address indexed caller, address indexed recipient, uint256 infIn, uint256 collateralOut);
    event Minted(
        address indexed caller, address indexed recipient, uint256 collateralIn, uint256 nanOut, uint256 feeUsd
    );
    event Redeemed(
        address indexed caller, address indexed recipient, uint256 nanIn, uint256 collateralOut, uint256 feeUsd
    );
    event Recapitalized(
        address indexed caller,
        address indexed recipient,
        address indexed retiredInf,
        address newInf,
        uint256 collateralIn,
        uint256 shortfallUsd,
        uint256 infOut,
        uint256 juniorSeries
    );

    constructor(
        IERC20 collateral_,
        IReserveOracle oracle_,
        uint256 maxDebtRatioBps_,
        uint256 mintFeeBps_,
        uint256 redeemFeeBps_
    ) {
        if (address(collateral_) == address(0) || address(oracle_) == address(0)) {
            revert ZeroAddress();
        }
        if (maxDebtRatioBps_ == 0 || maxDebtRatioBps_ >= BPS) revert InvalidConfiguration();
        if (mintFeeBps_ >= BPS || redeemFeeBps_ >= BPS) revert InvalidConfiguration();
        if (IERC20Metadata(address(collateral_)).decimals() != 18) revert UnsupportedCollateralDecimals();

        collateral = collateral_;
        oracle = oracle_;
        maxDebtRatioBps = maxDebtRatioBps_;
        mintFeeBps = mintFeeBps_;
        redeemFeeBps = redeemFeeBps_;

        nan = new NaNToken(address(this));
        inf = new INFToken(address(this));
        juniorSeries = 1;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function collateralPriceUsd() public view returns (uint256) {
        uint256 price = oracle.price();
        if (price == 0) revert InvalidPrice();
        return price;
    }

    /// @notice Redemption can use the immutable fallback when the primary oracle is unavailable.
    function redemptionCollateralPriceUsd() public view returns (uint256 price, bool fallbackUsed) {
        (price, fallbackUsed) = oracle.redemptionPrice();
        if (price == 0) revert InvalidPrice();
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
        return Math.mulDiv(debt, BPS, reserve);
    }

    /// @notice Reserve value divided by NaN liabilities, 1e18-scaled. Max uint when there is no debt.
    function collateralRatio() public view returns (uint256) {
        uint256 debt = debtUsd();
        if (debt == 0) return type(uint256).max;
        return Math.mulDiv(reserveUsd(), WAD, debt);
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
        return Math.mulDiv(equity, WAD, supply);
    }

    /// @notice Current NaN redemption price before the explicit redemption fee.
    /// @dev $1 when solvent; pro-rata reserve value when insolvent.
    function nanRedemptionPriceUsd() public view returns (uint256) {
        uint256 debt = debtUsd();
        if (debt == 0) return WAD;
        (uint256 collateralPrice,) = redemptionCollateralPriceUsd();
        uint256 reserve = _collateralToUsd(reserveCollateral(), collateralPrice);
        if (reserve >= debt) return WAD;
        return Math.mulDiv(reserve, WAD, debt);
    }

    /// @notice Maximum USD of residual reserve that INF holders may currently remove while preserving the max debt ratio.
    function maxDefundableUsd() public view returns (uint256) {
        uint256 reserve = reserveUsd();
        uint256 debt = debtUsd();
        if (debt == 0) return reserve;

        uint256 minReserve = Math.mulDiv(debt, BPS, maxDebtRatioBps, Math.Rounding.Ceil);
        if (reserve <= minReserve) return 0;
        return reserve - minReserve;
    }

    // -------------------------------------------------------------------------
    // State transitions
    // -------------------------------------------------------------------------

    /// @notice Add junior capital and mint INF at current residual NAV.
    /// @dev Initial INF starts at $1. Use recapitalize() at zero equity so underwater INF is not subsidized.
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
            if (debt != 0) revert RecapitalizationRequired();
            infOut = usdIn; // bootstrap at $1 per INF
        } else {
            if (reserveBefore <= debt) revert RecapitalizationRequired();
            uint256 equityBefore = reserveBefore - debt;
            infOut = Math.mulDiv(usdIn, infSupply, equityBefore);
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
        uint256 usdOut = Math.mulDiv(infIn, equityBefore, infSupply);
        collateralOut = debt == 0 && infIn == infSupply ? reserveCollateral() : _usdToCollateral(usdOut, price);
        if (collateralOut == 0 || collateralOut < minCollateralOut) revert Slippage();

        uint256 actualUsdOut = _collateralToUsd(collateralOut, price);
        uint256 reserveAfter = reserveBefore - actualUsdOut;
        if (!_withinMaxDebtRatio(debt, reserveAfter)) revert DebtRatioTooHigh();

        inf.burn(msg.sender, infIn);
        collateral.safeTransfer(recipient, collateralOut);

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
        if (inf.totalSupply() == 0) revert NoJuniorCapital();

        uint256 price = collateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        uint256 debtBefore = debtUsd();
        uint256 usdIn = _collateralToUsd(collateralIn, price);
        uint256 feeUsd = Math.mulDiv(usdIn, mintFeeBps, BPS);
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

        uint256 debtBefore = debtUsd();
        if (debtBefore == 0) revert NoDebt();
        (uint256 price,) = redemptionCollateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);

        uint256 redemptionPrice = reserveBefore >= debtBefore ? WAD : Math.mulDiv(reserveBefore, WAD, debtBefore);
        uint256 grossUsdOut = Math.mulDiv(nanIn, redemptionPrice, WAD);

        uint256 feeBps = reserveBefore > debtBefore ? redeemFeeBps : 0;
        uint256 feeUsd = Math.mulDiv(grossUsdOut, feeBps, BPS);
        uint256 netUsdOut = grossUsdOut - feeUsd;
        collateralOut = reserveBefore <= debtBefore && nanIn == debtBefore
            ? reserveCollateral()
            : _usdToCollateral(netUsdOut, price);

        if (collateralOut == 0 || collateralOut < minCollateralOut) revert Slippage();

        nan.burn(msg.sender, nanIn);
        collateral.safeTransfer(recipient, collateralOut);

        emit Redeemed(msg.sender, recipient, nanIn, collateralOut, feeUsd);
    }

    /// @notice Restore an insolvent reserve and replace the wiped-out junior token with a fresh series.
    /// @dev For outstanding NaN debt, the deposit must restore the configured healthy debt ratio.
    ///      New INF represents the post-recapitalization residual equity dollar-for-dollar. Retiring the
    ///      old INF series prevents underwater holders from receiving a windfall funded by the recapitalizer.
    function recapitalize(uint256 collateralIn, uint256 minInfOut, address recipient)
        external
        nonReentrant
        returns (uint256 infOut)
    {
        if (collateralIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 shortfallUsd;
        (shortfallUsd, infOut) = _recapitalizationQuote(collateralIn);
        if (infOut < minInfOut) revert Slippage();

        _pullExact(collateralIn);
        _replaceJuniorSeries(recipient, collateralIn, shortfallUsd, infOut);
    }

    // -------------------------------------------------------------------------
    // Internal math
    // -------------------------------------------------------------------------

    function _recapitalizationQuote(uint256 collateralIn) internal view returns (uint256 shortfallUsd, uint256 infOut) {
        uint256 price = collateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        uint256 debt = debtUsd();
        if (reserveBefore > debt || (debt == 0 && inf.totalSupply() == 0)) revert NotInsolvent();

        shortfallUsd = debt - reserveBefore;
        uint256 usdIn = _collateralToUsd(collateralIn, price);
        uint256 requiredReserve;
        if (debt != 0) {
            requiredReserve = Math.mulDiv(debt, BPS, maxDebtRatioBps, Math.Rounding.Ceil);
        }

        uint256 requiredUsdIn = requiredReserve > reserveBefore ? requiredReserve - reserveBefore : 0;
        if (usdIn < requiredUsdIn) revert InsufficientRecapitalization();

        infOut = reserveBefore + usdIn - debt;
        if (infOut == 0) revert Slippage();
    }

    function _replaceJuniorSeries(address recipient, uint256 collateralIn, uint256 shortfallUsd, uint256 infOut)
        internal
    {
        INFToken retiredInf = inf;
        INFToken newInf = new INFToken(address(this));
        inf = newInf;
        unchecked {
            ++juniorSeries;
        }
        newInf.mint(recipient, infOut);

        emit Recapitalized(
            msg.sender,
            recipient,
            address(retiredInf),
            address(newInf),
            collateralIn,
            shortfallUsd,
            infOut,
            juniorSeries
        );
    }

    function _collateralToUsd(uint256 collateralAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(collateralAmount, price, WAD);
    }

    function _usdToCollateral(uint256 usdAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(usdAmount, WAD, price);
    }

    function _withinMaxDebtRatio(uint256 debt, uint256 reserve) internal view returns (bool) {
        if (debt == 0) return true;
        if (reserve == 0) return false;
        return debt <= Math.mulDiv(reserve, maxDebtRatioBps, BPS);
    }

    function _pullExact(uint256 amount) internal {
        uint256 beforeBalance = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateral.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnsupportedTransferFee();
    }
}
