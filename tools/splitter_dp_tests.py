from itertools import product
from math import inf

TWO_WAY = 7.3

CASES = [
    ("A: 2-way only", [(2, TWO_WAY)]),
    ("B: 2/3/4-way, 3=1.6x, 4=2.2x",
     [(2, TWO_WAY), (3, round(TWO_WAY * 1.6, 2)), (4, round(TWO_WAY * 2.2, 2))]),
    ("C: 2/3/4-way, 3=1.4x, 4=1.8x",
     [(2, TWO_WAY), (3, round(TWO_WAY * 1.4, 2)), (4, round(TWO_WAY * 1.8, 2))]),
]

MAX_FANOUT = 16
EPS_KEY = 6


def compute_dp(types, max_s):
    dp = [None] * (max_s + 1)
    dp[1] = (0.0, None)
    for s in range(2, max_s + 1):
        best = None
        for t, (k, delay) in enumerate(types):
            if k < 2 or k > s:
                continue
            cost = delay + dp[(s + k - 1) // k][0]
            if best is None or cost < best[0]:
                best = (cost, t)
        dp[s] = best
    return dp


def dp_tree(s, types, dp):
    if s == 1:
        return [0.0], 0
    k, delay = types[dp[s][1]]
    base, rem = divmod(s, k)
    delays = []
    count = 1
    for j in range(k):
        share = base + (1 if j < rem else 0)
        child_delays, child_count = dp_tree(share, types, dp)
        delays.extend(d + delay for d in child_delays)
        count += child_count
    return delays, count


def balanced_binary_tree(s, delay=TWO_WAY):
    if s == 1:
        return [0.0], 0
    left = s // 2
    right = s - left
    left_delays, left_count = balanced_binary_tree(left, delay)
    right_delays, right_count = balanced_binary_tree(right, delay)
    delays = [d + delay for d in left_delays + right_delays]
    return delays, 1 + left_count + right_count


def partitions(n, k, min_part=1):
    if k == 1:
        if n >= min_part:
            yield (n,)
        return
    for first in range(min_part, n // k + 1):
        for rest in partitions(n - first, k - 1, first):
            yield (first,) + rest


def brute_force_frontiers(types, max_s):
    frontiers = {1: [(0.0, 0.0, 0)]}
    for s in range(2, max_s + 1):
        candidates = {}
        for k, delay in types:
            if k < 2 or k > s:
                continue
            for parts in partitions(s, k):
                child_frontiers = [frontiers[p] for p in parts]
                for combo in product(*child_frontiers):
                    lo = delay + min(c[0] for c in combo)
                    hi = delay + max(c[1] for c in combo)
                    splitters = 1 + sum(c[2] for c in combo)
                    key = (round(lo, EPS_KEY), round(hi, EPS_KEY))
                    if key not in candidates or splitters < candidates[key]:
                        candidates[key] = splitters

        items = sorted(
            ((lo, hi, sc) for (lo, hi), sc in candidates.items()),
            key=lambda x: (-x[0], x[1], x[2]),
        )
        frontier = []
        best_hi = inf
        for lo, hi, sc in items:
            if hi < best_hi:
                frontier.append((lo, hi, sc))
                best_hi = hi
        frontiers[s] = frontier
    return frontiers


def brute_force_tree(s, types, frontiers):
    lo, hi, splitters = min(frontiers[s], key=lambda t: (t[1], t[1] - t[0], t[2]))
    return lo, hi, hi - lo, splitters


def metrics(delays, splitters):
    return min(delays), max(delays), max(delays) - min(delays), splitters


def run():
    for case_name, types in CASES:
        dp = compute_dp(types, MAX_FANOUT)
        frontiers = brute_force_frontiers(types, MAX_FANOUT)
        delays_desc = ", ".join(f"{k}-way={d:g}ps" for k, d in types)
        print(f"\n### {case_name}  ({delays_desc})\n")
        print("| Fanout | Algorithm | Splitters | Min arrival | Max arrival | Skew |")
        print("|---:|---|---:|---:|---:|---:|")
        for fanout in range(2, MAX_FANOUT + 1):
            dp_delays, dp_count = dp_tree(fanout, types, dp)
            bin_delays, bin_count = balanced_binary_tree(fanout)
            brute_lo, brute_hi, brute_skew, brute_count = brute_force_tree(
                fanout, types, frontiers
            )
            rows = [
                ("DP (tool)", metrics(dp_delays, dp_count)),
                ("Balanced binary", metrics(bin_delays, bin_count)),
                ("Brute force", (brute_lo, brute_hi, brute_skew, brute_count)),
            ]
            for algorithm, (lo, hi, skew, count) in rows:
                print(
                    f"| {fanout} | {algorithm} | {count} | "
                    f"{lo:.2f} | {hi:.2f} | {skew:.2f} |"
                )


if __name__ == "__main__":
    run()
