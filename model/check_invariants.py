#!/usr/bin/env python3
import random

BPS=10_000
MAX_DR=6_500
MINT_FEE=10
REDEEM_FEE=10


def within(debt,reserve):
    if debt == 0: return True
    if reserve <= 0: return False
    return debt * BPS <= reserve * MAX_DR

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

# Recapitalization retires old junior claims and mints exactly the new equity.
for _ in range(100_000):
    debt=random.uniform(1,1e9)
    reserve=random.uniform(0,debt)
    shortfall=debt-reserve
    deposit=shortfall+random.uniform(0.001,1e9)
    new_inf=deposit-shortfall
    new_equity=reserve+deposit-debt
    if abs(new_inf-new_equity) > 1e-6:
        raise AssertionError('recapitalization invariant')

print('100k randomized checks per invariant: OK')
