#!/usr/bin/env python3
import random

random.seed(0x4E414E)

BPS=10_000
MAX_DR=6_500
TARGET_DR=5_500
MINT_FEE=10
REDEEM_FEE=10


def within(debt,reserve):
    if debt == 0: return True
    if reserve <= 0: return False
    return debt * BPS <= reserve * MAX_DR

def within_target(debt,reserve):
    if debt == 0: return True
    if reserve <= 0: return False
    return debt * BPS <= reserve * TARGET_DR

# Mint invariant: if allowed, resulting DR is <= MAX.
for _ in range(100_000):
    reserve=random.uniform(1,1e9)
    debt=random.uniform(0,reserve*MAX_DR/BPS)
    dep=random.uniform(0,1e8)
    nan=dep*(1-MINT_FEE/BPS)
    r2=reserve+dep
    d2=debt+nan
    allowed=within(d2,r2)
    if allowed and d2/r2 > MAX_DR/BPS + 1e-12:
        raise AssertionError('mint invariant')

# Healthy redemption should not worsen debt ratio.
for _ in range(100_000):
    reserve=random.uniform(1,1e9)
    debt=random.uniform(1,min(reserve,1e9))
    burn=random.uniform(0,debt)
    fee=min(burn*REDEEM_FEE/BPS, burn*(reserve-debt)/debt)
    net=burn-fee
    r2=reserve-net
    d2=debt-burn
    if d2 and d2/r2 > debt/reserve + 1e-12:
        raise AssertionError('redeem worsened health')

# Insolvent pro-rata redemption preserves reserve/debt ratio absent rounding.
for _ in range(100_000):
    debt=random.uniform(1,1e9)
    reserve=random.uniform(0.001,debt*0.999999)
    burn=random.uniform(0,debt*0.9)
    px=reserve/debt
    out=burn*px
    r2=reserve-out
    d2=debt-burn
    if abs((r2/d2)-(reserve/debt)) > 1e-9:
        raise AssertionError('pro-rata invariant')

WAD = 10**18


def redemption_fee(amount, reserve, debt, fee_bps):
    if reserve <= debt:
        return 0
    return min(amount * fee_bps // BPS, amount * (reserve - debt) // debt)


# Integer USD accounting: fees are proportional to surplus and bounded by the
# configured rate. Splitting recomputes the cap; retaining the first fee must
# not make the second burn cheaper (allow one USD base unit for fee flooring).
for _ in range(100_000):
    debt = random.randrange(2, 10**9 * WAD)
    equity = random.randrange(0, debt)
    reserve = debt + equity
    amount = random.randrange(2, debt + 1)
    first = random.randrange(1, amount)
    fee_bps = random.randrange(0, 1_001)
    fee = redemption_fee(amount, reserve, debt, fee_bps)
    assert 0 <= fee <= amount * fee_bps // BPS
    assert fee <= amount * equity // debt
    assert redemption_fee(amount, debt, debt, fee_bps) == 0
    donation = random.randrange(1, 10**6 * WAD)
    after_donation = redemption_fee(amount, reserve + donation, debt, fee_bps)
    assert 0 <= after_donation - fee <= (amount * donation + debt - 1) // debt
    first_fee = redemption_fee(first, reserve, debt, fee_bps)
    second_fee = redemption_fee(amount - first, reserve - first + first_fee, debt - first, fee_bps)
    assert first_fee + second_fee >= fee - 1
    assert first_fee + second_fee <= amount * fee_bps // BPS


# Same-token funding: integer arithmetic mirrors Solidity rounding. Splitting
# at the same price/time must not increase issuance, including across target.
def funding_quote(deposit, reserve, debt, supply, floor_price):
    if supply == 0:
        assert debt == 0
        return deposit
    equity = max(reserve - debt, 0)
    if equity * WAD // supply < floor_price:
        return deposit * WAD // floor_price
    return deposit * supply // equity


for _ in range(100_000):
    debt = random.randrange(WAD, 10**9 * WAD)
    reserve = random.randrange(0, debt * 10)
    supply = random.randrange(WAD, 10**12 * WAD)
    # Independent USD bounds include very low ratios and large recapitalizations.
    deposit = random.randrange(2, 10**10 * WAD)
    split = random.randrange(1, deposit)
    floor_price = random.randrange(1, 10 * WAD)
    minted = funding_quote(deposit, reserve, debt, supply, floor_price)
    first = funding_quote(split, reserve, debt, supply, floor_price)
    second = funding_quote(deposit - split, reserve + split, debt, supply + first, floor_price)
    if first + second > minted:
        raise AssertionError('splitting funding increased issuance')
    total_supply = supply + minted
    equity = max(reserve + deposit - debt, 0)
    nav = equity * WAD // total_supply
    if nav * total_supply // WAD > equity:
        raise AssertionError('reported junior claims exceed equity')
    if reserve <= debt and equity * minted // total_supply > deposit:
        raise AssertionError('recapitalizer received more NAV than contributed')
    # The old supply persists; dilution changes ownership, not token identity.
    if total_supply < supply:
        raise AssertionError('existing INF was cancelled')

# Normal NAV funding below 30% preserves existing claims within rounding.
# Independent collateral deposits have no ratio-based capacity restriction.
for _ in range(100_000):
    debt = random.randrange(0, 10**9 * WAD)
    reserve = debt * 4 + random.randrange(WAD, 10**10 * WAD)
    supply = random.randrange(WAD, 10**12 * WAD)
    deposit = random.randrange(2, 10**10 * WAD)
    split = random.randrange(1, deposit)
    equity = reserve - debt
    minted = funding_quote(deposit, reserve, debt, supply, 0)
    old_claim = (equity + deposit) * supply // (supply + minted)
    if not equity <= old_claim <= equity + (equity + supply - 1) // supply:
        raise AssertionError('NAV funding diluted existing claims or lost more than one base share')
    first = funding_quote(split, reserve, debt, supply, 0)
    second = funding_quote(deposit - split, reserve + split, debt, supply + first, 0)
    if first + second > minted:
        raise AssertionError('splitting normal funding increased issuance')
    # Bootstrap and subsequent debt-free funding keep the same exact NAV.
    bootstrap = funding_quote(deposit, 0, 0, 0, 0)
    if bootstrap != deposit or funding_quote(deposit, deposit, 0, bootstrap, 0) != deposit:
        raise AssertionError('debt-free funding price changed')

# The floor must remain positive and nonincreasing, including very long gaps.
def decayed_floor(initial, elapsed, period):
    n, remainder = divmod(elapsed, period)
    if n >= 256:
        return 1
    numerator = (initial >> n) * (2 * period - remainder)
    return max(1, (numerator + 2 * period - 1) // (2 * period))


for _ in range(100_000):
    initial = random.randrange(1, 10**40)
    period = random.randrange(3600, 30 * 86400 + 1)
    first = random.randrange(0, 1000 * period)
    second = random.randrange(first, 1001 * period)
    if not 1 <= decayed_floor(initial, second, period) <= decayed_floor(initial, first, period) <= initial:
        raise AssertionError('decay positivity or monotonicity invariant')

print('100k randomized checks per invariant: OK')
