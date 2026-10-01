// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReserveOracle} from "./interfaces/IReserveOracle.sol";
import {NaNToken} from "./NaNToken.sol";
import {INFToken} from "./INFToken.sol";

/// @title NaN Reserve
/// @notice Minimal pooled-reserve stablecoin inspired by the senior/junior economics of USM/FUM.
/// @dev NaN is the senior $1 claim. INF owns the residual reserve value and absorbs losses first.
///      The reserve is non-upgradeable; its authorizer can change bounded risk parameters and the oracle router.
contract NaNReserve is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000;
    uint256 public constant MIN_INF_WITHDRAWAL_DELAY = 1 days;
    uint256 public constant MAX_INF_WITHDRAWAL_DELAY = 30 days;
    uint256 public constant MIN_INF_WITHDRAWAL_EPOCH = 1 hours;
    uint256 public constant MAX_INF_WITHDRAWAL_EPOCH = 7 days;
    uint256 public constant INF_SETTLEMENT_WINDOW = 1 days;
    uint256 public constant MIN_RECOVERY_HALVING_PERIOD = 1 hours;
    uint256 public constant MAX_RECOVERY_HALVING_PERIOD = 30 days;

    error ZeroAmount();
    error ZeroAddress();
    error InvalidConfiguration();
    error InvalidPrice();
    error UnsupportedCollateralDecimals();
    error DebtRatioTooHigh();
    error DebtRatioTooLow();
    error NoDebt();
    error NoJuniorCapital();
    error Slippage();
    error UnsupportedTransferFee();
    error RecapitalizationRequired();
    error NotInsolvent();
    error WithdrawalNotReady();
    error WithdrawalWindowClosed();
    error WithdrawalNotExpired();
    error WithdrawalAlreadySettled();
    error WithdrawalNotSettled();
    error NoWithdrawalRequest();
    error WithdrawalRequestExists();
    error RenounceDisabled();

    enum Health {
        NoDebt,
        Healthy,
        Stressed,
        Insolvent
    }

    IERC20 public immutable collateral;
    IReserveOracle public oracle;
    NaNToken public immutable nan;
    /// @notice Permanent junior token; recapitalization dilutes, never replaces, existing INF.
    INFToken public immutable inf;
    /// @notice Legacy withdrawal namespace, permanently fixed at one (not a token version).
    uint256 public constant juniorSeries = 1;

    struct Recovery {
        uint256 startedAt;
        uint256 initialPriceUsd;
        uint256 halvingPeriod;
        uint256 exitDebtRatioBps;
    }

    /// @notice Pricing episode, active when initialPriceUsd != 0; independent of reported solvency.
    Recovery public recovery;
    uint256 public recoveryHalvingPeriod = 1 days;

    /// @notice Debt / reserve bounds in basis points, ordered min < target < max.
    uint256 public minDebtRatioBps;
    uint256 public targetDebtRatioBps;
    uint256 public maxDebtRatioBps;
    uint256 public mintFeeBps;
    uint256 public redeemFeeBps;
    /// @notice Delay for newly opened INF withdrawal cohorts; existing cohorts keep their maturity.
    uint256 public infWithdrawalDelay = 3 days;
    /// @notice Epoch length used from withdrawalEpochScheduleStart onward, initially one day.
    uint256 public infWithdrawalEpoch = 1 days;
    uint256 public withdrawalEpochScheduleStart;
    uint256 public withdrawalEpochScheduleFirstId;

    struct WithdrawalEpoch {
        INFToken token;
        uint256 requestedInf;
        uint256 filledInf;
        uint256 collateralOut;
        bool settled;
        uint64 maturity;
    }

    struct WithdrawalRequest {
        uint256 start;
        uint256 infAmount;
    }

    /// @notice The series namespace is retained for client compatibility and always equals one.
    mapping(uint256 series => mapping(uint256 epoch => WithdrawalEpoch)) public withdrawalEpochs;
    mapping(uint256 series => mapping(uint256 epoch => mapping(address account => WithdrawalRequest))) public
        withdrawalRequests;
    /// @notice Settled withdrawal collateral is excluded from reserve backing until users claim it.
    uint256 public claimableWithdrawalCollateral;

    event Funded(address indexed caller, address indexed recipient, uint256 collateralIn, uint256 infOut);
    event Defunded(address indexed caller, address indexed recipient, uint256 infIn, uint256 collateralOut);
    event WithdrawalRequested(address indexed account, uint256 indexed series, uint256 indexed epoch, uint256 infIn);
    event WithdrawalSettled(uint256 indexed series, uint256 indexed epoch, uint256 filledInf, uint256 collateralOut);
    event WithdrawalExpired(uint256 indexed series, uint256 indexed epoch);
    event WithdrawalClaimed(
        address indexed account,
        address indexed recipient,
        uint256 indexed series,
        uint256 epoch,
        uint256 filledInf,
        uint256 collateralOut,
        uint256 refundedInf
    );
    event Minted(
        address indexed caller, address indexed recipient, uint256 collateralIn, uint256 nanOut, uint256 feeUsd
    );
    event Redeemed(
        address indexed caller, address indexed recipient, uint256 nanIn, uint256 collateralOut, uint256 feeUsd
    );
    event Recapitalized(
        address indexed caller, address indexed recipient, uint256 collateralIn, uint256 shortfallUsd, uint256 infOut
    );
    event RecoveryStarted(uint256 initialPriceUsd, uint256 halvingPeriod, uint256 exitDebtRatioBps);
    event RecoveryEnded();
    event RecoveryHalvingPeriodUpdated(uint256 previousPeriod, uint256 newPeriod);
    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event DebtRatiosUpdated(uint256 minDebtRatioBps, uint256 targetDebtRatioBps, uint256 maxDebtRatioBps);
    event FeesUpdated(uint256 mintFeeBps, uint256 redeemFeeBps);
    event InfWithdrawalDelayUpdated(uint256 previousDelay, uint256 newDelay);
    event InfWithdrawalEpochUpdated(uint256 previousLength, uint256 newLength, uint256 effectiveAt);

    constructor(
        IERC20 collateral_,
        IReserveOracle oracle_,
        address authorizer_,
        uint256 minDebtRatioBps_,
        uint256 targetDebtRatioBps_,
        uint256 maxDebtRatioBps_,
        uint256 mintFeeBps_,
        uint256 redeemFeeBps_
    ) Ownable(authorizer_) {
        if (address(collateral_) == address(0) || address(oracle_) == address(0)) {
            revert ZeroAddress();
        }
        if (IERC20Metadata(address(collateral_)).decimals() != 18) revert UnsupportedCollateralDecimals();

        collateral = collateral_;
        _setOracle(oracle_);
        _setDebtRatios(minDebtRatioBps_, targetDebtRatioBps_, maxDebtRatioBps_);
        _setFees(mintFeeBps_, redeemFeeBps_);

        nan = new NaNToken(address(this));
        inf = new INFToken(address(this));
    }

    /// @notice Rotate the full oracle router, including primary feed and fallback configuration.
    function setOracle(IReserveOracle newOracle) external onlyOwner {
        _setOracle(newOracle);
    }

    function setDebtRatios(uint256 minBps, uint256 targetBps, uint256 maxBps) external onlyOwner {
        _setDebtRatios(minBps, targetBps, maxBps);
    }

    function setFees(uint256 mintBps, uint256 redeemBps) external onlyOwner {
        _setFees(mintBps, redeemBps);
    }

    /// @notice Set decay speed for future recovery episodes only.
    function setRecoveryHalvingPeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod < MIN_RECOVERY_HALVING_PERIOD || newPeriod > MAX_RECOVERY_HALVING_PERIOD) {
            revert InvalidConfiguration();
        }
        uint256 previousPeriod = recoveryHalvingPeriod;
        recoveryHalvingPeriod = newPeriod;
        emit RecoveryHalvingPeriodUpdated(previousPeriod, newPeriod);
    }

    /// @notice Change the delay for future cohorts only; requests already in a cohort are unaffected.
    function setInfWithdrawalDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_INF_WITHDRAWAL_DELAY || newDelay > MAX_INF_WITHDRAWAL_DELAY) {
            revert InvalidConfiguration();
        }
        uint256 previousDelay = infWithdrawalDelay;
        infWithdrawalDelay = newDelay;
        emit InfWithdrawalDelayUpdated(previousDelay, newDelay);
    }

    /// @notice Change batching length at the next epoch boundary, preserving the current epoch.
    /// @dev Another update before that boundary replaces the pending length without moving the boundary.
    function setInfWithdrawalEpoch(uint256 newLength) external onlyOwner {
        if (newLength < MIN_INF_WITHDRAWAL_EPOCH || newLength > MAX_INF_WITHDRAWAL_EPOCH) {
            revert InvalidConfiguration();
        }
        (uint256 epoch, uint256 endsAt) = currentWithdrawalEpoch();
        uint256 previousLength = infWithdrawalEpoch;
        withdrawalEpochScheduleFirstId = epoch + 1;
        withdrawalEpochScheduleStart = endsAt;
        infWithdrawalEpoch = newLength;
        emit InfWithdrawalEpochUpdated(previousLength, newLength, endsAt);
    }

    /// @notice Configuration must always have an authorizer able to rotate failed dependencies.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function _setOracle(IReserveOracle newOracle) internal {
        if (address(newOracle) == address(0)) revert ZeroAddress();
        if (address(newOracle).code.length == 0) revert InvalidConfiguration();
        if (newOracle.price() == 0) revert InvalidPrice();
        (uint256 redemptionPrice,) = newOracle.redemptionPrice();
        if (redemptionPrice == 0) revert InvalidPrice();
        address previous = address(oracle);
        oracle = newOracle;
        emit OracleUpdated(previous, address(newOracle));
    }

    function _setDebtRatios(uint256 minBps, uint256 targetBps, uint256 maxBps) internal {
        if (minBps == 0 || minBps >= targetBps || targetBps >= maxBps || maxBps >= BPS) {
            revert InvalidConfiguration();
        }
        minDebtRatioBps = minBps;
        targetDebtRatioBps = targetBps;
        maxDebtRatioBps = maxBps;
        emit DebtRatiosUpdated(minBps, targetBps, maxBps);
    }

    function _setFees(uint256 mintBps, uint256 redeemBps) internal {
        if (mintBps > MAX_FEE_BPS || redeemBps > MAX_FEE_BPS) revert InvalidConfiguration();
        mintFeeBps = mintBps;
        redeemFeeBps = redeemBps;
        emit FeesUpdated(mintBps, redeemBps);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function collateralPriceUsd() public view returns (uint256) {
        uint256 price = oracle.price();
        if (price == 0) revert InvalidPrice();
        return price;
    }

    /// @notice Redemption can use the configured fallback when the primary oracle is unavailable.
    function redemptionCollateralPriceUsd() public view returns (uint256 price, bool fallbackUsed) {
        (price, fallbackUsed) = oracle.redemptionPrice();
        if (price == 0) revert InvalidPrice();
    }

    function reserveCollateral() public view returns (uint256) {
        return collateral.balanceOf(address(this)) - claimableWithdrawalCollateral;
    }

    /// @notice Current batching epoch ID and its fixed closing timestamp.
    /// @dev IDs are monotonic across schedule changes; clients must not derive them by dividing timestamps.
    function currentWithdrawalEpoch() public view returns (uint256 epoch, uint256 endsAt) {
        uint256 start = withdrawalEpochScheduleStart;
        uint256 firstId = withdrawalEpochScheduleFirstId;
        if (block.timestamp < start) return (firstId - 1, start);
        uint256 offset = (block.timestamp - start) / infWithdrawalEpoch;
        return (firstId + offset, start + (offset + 1) * infWithdrawalEpoch);
    }

    /// @notice The fixed maturity of an opened series-specific withdrawal cohort.
    function withdrawalMaturity(uint256 series, uint256 epoch) public view returns (uint256) {
        WithdrawalEpoch storage requestEpoch = withdrawalEpochs[series][epoch];
        if (requestEpoch.requestedInf == 0) revert NoWithdrawalRequest();
        return requestEpoch.maturity;
    }

    function withdrawalExpiry(uint256 series, uint256 epoch) public view returns (uint256) {
        return withdrawalMaturity(series, epoch) + INF_SETTLEMENT_WINDOW;
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

    /// @notice Maximum USD of residual reserve that INF holders may remove while preserving the target ratio.
    function maxDefundableUsd() public view returns (uint256) {
        uint256 reserve = reserveUsd();
        uint256 debt = debtUsd();
        if (debt == 0) return reserve;

        uint256 minReserve = Math.mulDiv(debt, BPS, targetDebtRatioBps, Math.Rounding.Ceil);
        if (reserve <= minReserve) return 0;
        return reserve - minReserve;
    }

    /// @notice Approximate additional USD of INF funding allowed before reaching the minimum debt ratio.
    /// @dev With no debt, initial junior funding is uncapped.
    function maxFundableUsd() public view returns (uint256) {
        uint256 debt = debtUsd();
        if (debt == 0) return type(uint256).max;
        uint256 reserve = reserveUsd();
        uint256 maxReserve = Math.mulDiv(debt, BPS, minDebtRatioBps);
        return reserve >= maxReserve ? 0 : maxReserve - reserve;
    }

    /// @notice Effective issuance floor after a fresh primary observation; zero outside recovery pricing.
    /// @dev This view does not persist an observation or start the clock.
    function recoveryFloorPriceUsd() public view returns (uint256) {
        return _decayedFloor(_recoveryAt(reserveUsd(), debtUsd(), inf.totalSupply()));
    }

    /// @notice Marginal funding price, rounded up; NOT a redemption price or guaranteed market value.
    function fundingPriceUsd() external view returns (uint256) {
        uint256 supply = inf.totalSupply();
        if (supply == 0) return WAD;
        uint256 reserve = reserveUsd();
        uint256 debt = debtUsd();
        uint256 equity = reserve > debt ? reserve - debt : 0;
        uint256 floor = _decayedFloor(_recoveryAt(reserve, debt, supply));
        return Math.max(floor, Math.mulDiv(equity, WAD, supply, Math.Rounding.Ceil));
    }

    /// @notice Quote same-token issuance using the current primary price, state and timestamp.
    function previewFund(uint256 collateralIn) external view returns (uint256) {
        if (collateralIn == 0) revert ZeroAmount();
        uint256 price = collateralPriceUsd();
        uint256 reserve = _collateralToUsd(reserveCollateral(), price);
        uint256 debt = debtUsd();
        uint256 supply = inf.totalSupply();
        _checkFundingCap(collateralIn, price, debt);
        return _fundingQuote(
            _collateralToUsd(collateralIn, price),
            reserve,
            debt,
            supply,
            _decayedFloor(_recoveryAt(reserve, debt, supply))
        );
    }

    /// @notice Permissionless primary-only observation. Cannot prove continuous distress between calls.
    function checkpointRecovery() external nonReentrant {
        _syncRecovery(reserveUsd(), debtUsd(), inf.totalSupply());
    }

    // -------------------------------------------------------------------------
    // State transitions
    // -------------------------------------------------------------------------

    /// @notice Add junior capital at the greater of real NAV and the recovery issuance floor.
    /// @dev Partial funding is allowed even at zero equity. Existing INF shares are never retired.
    function fund(uint256 collateralIn, uint256 minInfOut, address recipient)
        external
        nonReentrant
        returns (uint256 infOut)
    {
        return _fund(collateralIn, minInfOut, recipient, false);
    }

    function _fund(uint256 collateralIn, uint256 minInfOut, address recipient, bool insolventOnly)
        internal
        returns (uint256 infOut)
    {
        if (collateralIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 price = collateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        uint256 debt = debtUsd();
        uint256 infSupply = inf.totalSupply();
        if (insolventOnly && (reserveBefore > debt || infSupply == 0)) {
            revert NotInsolvent();
        }
        _checkFundingCap(collateralIn, price, debt);
        _syncRecovery(reserveBefore, debt, infSupply);
        infOut = _fundingQuote(
            _collateralToUsd(collateralIn, price), reserveBefore, debt, infSupply, _decayedFloor(recovery)
        );
        if (infOut == 0 || infOut < minInfOut) revert Slippage();
        _pullExact(collateralIn);
        inf.mint(recipient, infOut);
        _syncRecovery(_collateralToUsd(reserveCollateral(), price), debt, inf.totalSupply());

        emit Funded(msg.sender, recipient, collateralIn, infOut);
        if (insolventOnly) emit Recapitalized(msg.sender, recipient, collateralIn, debt - reserveBefore, infOut);
    }

    /// @notice Lock active INF for a withdrawal. No collateral amount is fixed at request time.
    /// @dev Requests in the same epoch share the delay snapshotted when its cohort first opens.
    function requestDefund(uint256 infIn) external nonReentrant returns (uint256 series, uint256 epoch) {
        if (infIn == 0) revert ZeroAmount();
        series = juniorSeries;
        uint256 endsAt;
        (epoch, endsAt) = currentWithdrawalEpoch();
        WithdrawalEpoch storage requestEpoch = withdrawalEpochs[series][epoch];
        WithdrawalRequest storage request = withdrawalRequests[series][epoch][msg.sender];
        if (request.infAmount != 0) revert WithdrawalRequestExists();
        if (address(requestEpoch.token) == address(0)) {
            requestEpoch.token = inf;
            requestEpoch.maturity = SafeCast.toUint64(endsAt + infWithdrawalDelay);
        }

        IERC20(address(inf)).safeTransferFrom(msg.sender, address(this), infIn);
        request.start = requestEpoch.requestedInf;
        request.infAmount = infIn;
        requestEpoch.requestedInf += infIn;

        emit WithdrawalRequested(msg.sender, series, epoch, infIn);
    }

    /// @notice Settle a matured cohort at the then-current price and debt ratio; anyone may call this.
    /// @dev A cohort can be partially filled, with the unfilled INF returned during claim.
    function settleDefundEpoch(uint256 series, uint256 epoch) external nonReentrant {
        WithdrawalEpoch storage requestEpoch = withdrawalEpochs[series][epoch];
        if (requestEpoch.requestedInf == 0) revert NoWithdrawalRequest();
        if (requestEpoch.settled) revert WithdrawalAlreadySettled();
        if (block.timestamp < requestEpoch.maturity) revert WithdrawalNotReady();
        if (block.timestamp >= uint256(requestEpoch.maturity) + INF_SETTLEMENT_WINDOW) {
            revert WithdrawalWindowClosed();
        }

        uint256 filledInf;
        uint256 collateralOut;
        if (address(requestEpoch.token) == address(inf)) {
            (filledInf, collateralOut) = _withdrawalQuote(requestEpoch.requestedInf);
        }

        requestEpoch.settled = true;
        requestEpoch.filledInf = filledInf;
        requestEpoch.collateralOut = collateralOut;
        if (filledInf != 0) requestEpoch.token.burn(address(this), filledInf);
        claimableWithdrawalCollateral += collateralOut;

        emit WithdrawalSettled(series, epoch, filledInf, collateralOut);
    }

    /// @notice Release requests if their one-day settlement window passed without a valid settlement.
    function expireDefundEpoch(uint256 series, uint256 epoch) external {
        WithdrawalEpoch storage requestEpoch = withdrawalEpochs[series][epoch];
        if (requestEpoch.requestedInf == 0) revert NoWithdrawalRequest();
        if (requestEpoch.settled) revert WithdrawalAlreadySettled();
        if (block.timestamp < uint256(requestEpoch.maturity) + INF_SETTLEMENT_WINDOW) revert WithdrawalNotExpired();

        requestEpoch.settled = true;
        emit WithdrawalExpired(series, epoch);
    }

    /// @notice Claim fixed collateral and any INF not filled by the settled epoch.
    function claimDefund(uint256 series, uint256 epoch, uint256 minCollateralOut, address recipient)
        external
        nonReentrant
        returns (uint256 collateralOut, uint256 refundedInf)
    {
        if (recipient == address(0)) revert ZeroAddress();
        WithdrawalEpoch storage requestEpoch = withdrawalEpochs[series][epoch];
        if (!requestEpoch.settled) revert WithdrawalNotSettled();
        WithdrawalRequest storage request = withdrawalRequests[series][epoch][msg.sender];
        uint256 requestedInf = request.infAmount;
        if (requestedInf == 0) revert NoWithdrawalRequest();

        // Each request owns a disjoint interval of the epoch. Difference-of-prefixes
        // distributes every unit exactly without a first/last claimant advantage.
        uint256 end = request.start + requestedInf;
        uint256 filledInf = Math.mulDiv(end, requestEpoch.filledInf, requestEpoch.requestedInf)
            - Math.mulDiv(request.start, requestEpoch.filledInf, requestEpoch.requestedInf);
        collateralOut = Math.mulDiv(end, requestEpoch.collateralOut, requestEpoch.requestedInf)
            - Math.mulDiv(request.start, requestEpoch.collateralOut, requestEpoch.requestedInf);
        if (collateralOut < minCollateralOut) revert Slippage();
        refundedInf = requestedInf - filledInf;

        delete withdrawalRequests[series][epoch][msg.sender];
        claimableWithdrawalCollateral -= collateralOut;

        if (refundedInf != 0) IERC20(address(requestEpoch.token)).safeTransfer(msg.sender, refundedInf);
        if (collateralOut != 0) collateral.safeTransfer(recipient, collateralOut);

        emit WithdrawalClaimed(msg.sender, recipient, series, epoch, filledInf, collateralOut, refundedInf);
        if (filledInf != 0) emit Defunded(msg.sender, recipient, filledInf, collateralOut);
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
        _syncRecovery(reserveBefore, debtBefore, inf.totalSupply());
        uint256 usdIn = _collateralToUsd(collateralIn, price);
        uint256 feeUsd = Math.mulDiv(usdIn, mintFeeBps, BPS);
        nanOut = usdIn - feeUsd;

        if (nanOut == 0 || nanOut < minNanOut) revert Slippage();
        uint256 reserveAfter = reserveBefore + usdIn;
        uint256 debtAfter = debtBefore + nanOut;
        if (!_withinMaxDebtRatio(debtAfter, reserveAfter)) revert DebtRatioTooHigh();

        _pullExact(collateralIn);
        nan.mint(recipient, nanOut);
        _syncRecovery(_collateralToUsd(reserveCollateral(), price), debtAfter, inf.totalSupply());

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
        (uint256 price, bool fallbackUsed) = redemptionCollateralPriceUsd();
        uint256 reserveBefore = _collateralToUsd(reserveCollateral(), price);
        if (!fallbackUsed) _syncRecovery(reserveBefore, debtBefore, inf.totalSupply());

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
        if (!fallbackUsed) {
            _syncRecovery(_collateralToUsd(reserveCollateral(), price), debtUsd(), inf.totalSupply());
        }

        emit Redeemed(msg.sender, recipient, nanIn, collateralOut, feeUsd);
    }

    /// @notice Insolvency-only convenience entry point for same-token, incremental funding.
    /// @dev Same quote as fund(); no minimum target-restoring deposit and no old-share cancellation.
    function recapitalize(uint256 collateralIn, uint256 minInfOut, address recipient)
        external
        nonReentrant
        returns (uint256 infOut)
    {
        return _fund(collateralIn, minInfOut, recipient, true);
    }

    // -------------------------------------------------------------------------
    // Internal math
    // -------------------------------------------------------------------------

    function _withdrawalQuote(uint256 requestedInf) internal returns (uint256 filledInf, uint256 collateralOut) {
        uint256 supply = inf.totalSupply(); // Includes INF locked by all unsettled cohorts.
        uint256 reserve = reserveCollateral();
        uint256 debt = debtUsd();

        if (debt == 0) {
            filledInf = requestedInf;
            collateralOut = requestedInf == supply ? reserve : Math.mulDiv(requestedInf, reserve, supply);
            return (filledInf, collateralOut);
        }

        uint256 price = collateralPriceUsd();
        uint256 reserveValue = _collateralToUsd(reserve, price);
        _syncRecovery(reserveValue, debt, supply);
        if (reserveValue <= debt) return (0, 0);

        uint256 minimumReserveUsd = Math.mulDiv(debt, BPS, targetDebtRatioBps, Math.Rounding.Ceil);
        if (reserveValue <= minimumReserveUsd) return (0, 0);
        uint256 minimumReserveCollateral = Math.mulDiv(minimumReserveUsd, WAD, price, Math.Rounding.Ceil);
        if (reserve <= minimumReserveCollateral) return (0, 0);

        uint256 availableCollateral = reserve - minimumReserveCollateral;
        uint256 equity = reserveValue - debt;
        uint256 maximumUsdOut = _collateralToUsd(availableCollateral, price);
        filledInf = Math.min(requestedInf, Math.mulDiv(maximumUsdOut, supply, equity));
        collateralOut = _usdToCollateral(Math.mulDiv(filledInf, equity, supply), price);
        if (collateralOut == 0) return (0, 0);

        if (!_withinDebtRatio(debt, _collateralToUsd(reserve - collateralOut, price), targetDebtRatioBps)) {
            revert DebtRatioTooHigh();
        }
    }

    function _checkFundingCap(uint256 collateralIn, uint256 price, uint256 debt) internal view {
        if (
            debt != 0
                && _collateralToUsd(reserveCollateral() + collateralIn, price) > Math.mulDiv(debt, BPS, minDebtRatioBps)
        ) {
            revert DebtRatioTooLow();
        }
    }

    function _fundingQuote(uint256 usdIn, uint256 reserve, uint256 debt, uint256 supply, uint256 floor)
        internal
        pure
        returns (uint256)
    {
        if (supply == 0) {
            if (debt != 0) revert RecapitalizationRequired();
            return usdIn;
        }
        uint256 equity = reserve > debt ? reserve - debt : 0;
        if (floor != 0 && Math.mulDiv(equity, WAD, supply) < floor) {
            return Math.mulDiv(usdIn, WAD, floor);
        }
        // Keep the exact NAV ratio to avoid cheap issuance from a rounded-down per-token price.
        return Math.mulDiv(usdIn, supply, equity);
    }

    function _recoveryAt(uint256 reserve, uint256 debt, uint256 supply) internal view returns (Recovery memory next) {
        next = recovery;
        if (supply == 0) return Recovery(0, 0, 0, 0);
        if (next.initialPriceUsd != 0) {
            uint256 equity = reserve > debt ? reserve - debt : 0;
            if (
                _withinDebtRatio(debt, reserve, next.exitDebtRatioBps)
                    && Math.mulDiv(equity, WAD, supply) >= _decayedFloor(next)
            ) return Recovery(0, 0, 0, 0);
        } else if (!_withinMaxDebtRatio(debt, reserve) || reserve == 0) {
            // Price at the max-ratio boundary, not the potentially near-zero crash NAV.
            uint256 boundaryEquity = Math.mulDiv(debt, BPS - maxDebtRatioBps, maxDebtRatioBps, Math.Rounding.Ceil);
            uint256 initialPrice =
                debt == 0 ? WAD : Math.max(1, Math.mulDiv(boundaryEquity, WAD, supply, Math.Rounding.Ceil));
            // A return to the healthy band ends an observed crash once real NAV
            // has caught up to the floor. The NAV check prevents a split deposit
            // from making its second tranche cheaper at the ratio boundary.
            next = Recovery(block.timestamp, initialPrice, recoveryHalvingPeriod, maxDebtRatioBps);
        }
    }

    function _syncRecovery(uint256 reserve, uint256 debt, uint256 supply) internal {
        Recovery memory next = _recoveryAt(reserve, debt, supply);
        if (recovery.initialPriceUsd == 0 && next.initialPriceUsd != 0) {
            recovery = next;
            emit RecoveryStarted(next.initialPriceUsd, next.halvingPeriod, next.exitDebtRatioBps);
        } else if (recovery.initialPriceUsd != 0 && next.initialPriceUsd == 0) {
            delete recovery;
            emit RecoveryEnded();
        }
    }

    function _decayedFloor(Recovery memory episode) internal view returns (uint256) {
        if (episode.initialPriceUsd == 0) return 0;
        uint256 elapsed = block.timestamp - episode.startedAt;
        uint256 halvings = elapsed / episode.halvingPeriod;
        if (halvings >= 256) return 1;
        uint256 upper = episode.initialPriceUsd >> halvings;
        uint256 twicePeriod = 2 * episode.halvingPeriod;
        return
            Math.max(
                1, Math.mulDiv(upper, twicePeriod - elapsed % episode.halvingPeriod, twicePeriod, Math.Rounding.Ceil)
            );
    }

    function _collateralToUsd(uint256 collateralAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(collateralAmount, price, WAD);
    }

    function _usdToCollateral(uint256 usdAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(usdAmount, WAD, price);
    }

    function _withinMaxDebtRatio(uint256 debt, uint256 reserve) internal view returns (bool) {
        return _withinDebtRatio(debt, reserve, maxDebtRatioBps);
    }

    function _withinDebtRatio(uint256 debt, uint256 reserve, uint256 ratioBps) internal pure returns (bool) {
        if (debt == 0) return true;
        if (reserve == 0) return false;
        return debt <= Math.mulDiv(reserve, ratioBps, BPS);
    }

    function _pullExact(uint256 amount) internal {
        uint256 beforeBalance = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateral.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert UnsupportedTransferFee();
    }
}
