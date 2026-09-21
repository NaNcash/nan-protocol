#!/usr/bin/env python3
"""Tiny deterministic model for NaN v0 economics.

No chain dependencies. Values are USD floats purely for design exploration.
"""
from dataclasses import dataclass


@dataclass
class State:
    reserve: float
    nan: float
    inf: float

    @property
    def equity(self) -> float:
        return max(self.reserve - self.nan, 0.0)

    @property
    def inf_price(self) -> float:
        return self.equity / self.inf if self.inf else 1.0

    @property
    def debt_ratio(self) -> float:
        return self.nan / self.reserve if self.reserve else float("inf")


def show(label: str, s: State) -> None:
    print(
        f"{label:22} reserve=${s.reserve:,.0f}  NaN=${s.nan:,.0f}  "
        f"equity=${s.equity:,.0f}  INF=${s.inf_price:,.4f}  debt_ratio={s.debt_ratio:.2%}"
    )


s = State(reserve=300_000, nan=0, inf=300_000)
show("initial junior fund", s)

# $540k collateral deposited to mint NaN, with a 10 bp mint fee.
collateral_in = 540_000
mint_fee = 0.001
s.reserve += collateral_in
s.nan += collateral_in * (1 - mint_fee)
show("after NaN mint", s)

# 1% increase in wstETH value from staking rewards.
s.reserve *= 1.01
show("after 1% yield", s)

# 25% ETH/wstETH market drawdown.
s.reserve *= 0.75
show("after 25% drawdown", s)

# Another 25% drawdown from that level.
s.reserve *= 0.75
show("after second -25%", s)

# A recapitalizer fills the NaN shortfall. The old INF series is retired and
# only the value above the shortfall becomes new INF at $1.
recap_in = 100_000
shortfall = max(s.nan - s.reserve, 0.0)
s.reserve += recap_in
s.inf = recap_in - shortfall
show("after recapitalization", s)
