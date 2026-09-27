#!/usr/bin/env python3
import random

random.seed(0x4E414E)

BPS=10_000
MAX_DR=6_500
TARGET_DR=5_500
MIN_DR=3_000
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
    net=burn*(1-REDEEM_FEE/BPS)
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

# Same-token funding: integer arithmetic mirrors Solidity rounding. Splitting
# at the same price/time must not increase issuance, including across target.
WAD = 10**18


def funding_quote(deposit, reserve, debt, supply, floor_price):
    equity = max(reserve - debt, 0)
    if equity * WAD // supply < floor_price:
        return deposit * WAD // floor_price
    return deposit * supply // equity


for _ in range(100_000):
    debt = random.randrange(WAD, 10**9 * WAD)
    reserve = random.randrange(0, debt * 2)
    supply = random.randrange(WAD, 10**12 * WAD)
    max_deposit = debt * BPS // MIN_DR - reserve
    deposit = random.randrange(2, max_deposit)
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
    if debt * BPS < (reserve + deposit) * MIN_DR:
        raise AssertionError('funding breached minimum debt ratio')
    if reserve <= debt and equity * minted // total_supply > deposit:
        raise AssertionError('recapitalizer received more NAV than contributed')
    # The old supply persists; dilution changes ownership, not token identity.
    if total_supply < supply:
        raise AssertionError('existing INF was cancelled')

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
