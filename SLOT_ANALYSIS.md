# Slot Analysis — Methodology

Technical documentation for LootScope's Slot Analysis tab. Explains the statistical model, why each method was chosen, and what alternatives were considered.

## The FFXI Drop Model

FFXI's loot system (based on server emulator code from LandSandBoat) works as **N independent Bernoulli slots**. Each mob has a drop table with N slots, each slot rolls independently with its own probability. An item either drops or it doesn't. A mob with 4 drop slots makes 4 independent rolls per kill.

This model is the foundation of all Slot Analysis statistics. Every section tests, measures, or infers properties of these independent slots.

## Methods

### Wilson Score Confidence Intervals

**What it does**: Gives a 95% confidence interval for each item's true drop rate based on observed drops/kills.

**Why Wilson and not alternatives**:

| Method | Problem |
|--------|---------|
| **Wald (normal)** | Breaks for small samples and rates near 0% or 100%. Can produce negative lower bounds. The textbook `p +/- z*sqrt(p(1-p)/n)` formula is unreliable below ~100 trials. |
| **Clopper-Pearson (exact)** | Overly conservative — intervals are wider than necessary, especially at small n. Guarantees >= 95% coverage but often gives 98-99%, wasting statistical power. |
| **Agresti-Coull** | Similar to Wilson but less precise. Adds 2 pseudo-successes and 2 pseudo-failures before computing the Wald interval — an approximation of what Wilson does exactly. |
| **Wilson** | Well-behaved at any sample size and any rate. Never produces negative bounds. Recommended by most modern statistics references for binomial proportions. Standard choice. |

**Implementation**: `wilson_ci()` in `analysis.lua`. Uses z=1.96 for 95% confidence.

**UI display**: Reliability badges (High/Medium/Low) are derived from the CI width — narrower intervals mean more reliable estimates.

### Poisson Binomial Distribution

**What it does**: Computes the exact probability distribution for "how many items drop per kill" under the independent slot model.

**Why Poisson Binomial and not alternatives**:

| Method | Problem |
|--------|---------|
| **Regular Binomial** | Assumes all trials have the **same** probability. Wrong — each item has a different drop rate (e.g., one item at 50%, another at 5%). |
| **Poisson approximation** | Only accurate when n is large and individual probabilities are small. FFXI drops often have rates of 20-50%, violating this assumption. |
| **Normal approximation** | Requires large n and probabilities not near 0 or 1. Same problem as Poisson for typical FFXI data. |
| **Monte Carlo simulation** | Accurate but too expensive to run per-frame in a game addon. Would need thousands of iterations for each mob. |
| **Poisson Binomial** | The **exact** distribution for N independent trials with **different** probabilities. No approximation needed. |

**Implementation**: `poisson_binomial_pmf()` in `analysis.lua`. Uses O(n^2) dynamic programming. Capped at 30 items (no FFXI mob has more than 30 non-gil drops). The DP processes items one at a time, updating the probability of getting exactly k successes after each item.

**What it reveals**: Comparing the observed items-per-kill histogram against the Poisson Binomial expected values shows how well the independent slot model fits. Large deviations suggest shared slots, conditional drops, or other non-independent mechanics.

### Slot Count Estimation

**What it does**: Estimates how many independent drop slots a mob has.

**Method**: Uses two complementary bounds:

- **Lower bound**: `max_items_per_kill` — if you've ever seen 4 items drop from one kill, there are at least 4 slots. This is a hard floor.
- **Upper bound indicator**: `ceil(rate_sum)` — the sum of all observed drop rates. If rates sum to 2.3, there are at least 3 slots (rates can't exceed 1.0 per slot without multiple slots contributing). Rate sum > 1.0 proves multiple slots.
- **Estimated slots**: `max(max_items_per_kill, ceil(rate_sum))` — the best evidence from both signals.

**Empty kill model fit**: Compares observed empty kill rate against the expected rate from the independent model (`product of (1 - p_i)` for all items). Good agreement validates the slot count estimate. Poor agreement suggests hidden mechanics.

### Co-occurrence Analysis

**What it does**: Measures how often pairs of items drop together compared to what independence would predict.

**Method**: For each pair of items A and B:
- `expected_co = P(A) * P(B) * kills` — how often they should co-occur if independent
- `deviation = observed_co / expected_co` — ratio of actual to expected

**Interpreting deviation**:
- `~1.0` = independent (items are on separate slots, each rolling independently)
- `<1.0` = mutually exclusive (items likely share a slot — only one can drop per kill)
- `>1.0` = positively correlated (unusual — may indicate conditional drops or linked mechanics)

**Why not chi-squared or Fisher's exact test**:

| Method | Problem |
|--------|---------|
| **Chi-squared** | Outputs a p-value, not an interpretable magnitude. Requires expected counts >= 5 in all cells. Tells you "statistically significant" but not "how much." |
| **Fisher's exact** | Same p-value problem. Computationally expensive for large tables. |
| **Deviation ratio** | Directly readable: "these items appear together 0.2x as often as expected" is immediately useful. No statistical training required to interpret. |

**Minimum thresholds**: Both items need >= 5 drops (`MIN_ITEM_DROPS_PAIR`) and the mob needs >= 50 kills (`MIN_KILLS_COOCCURRENCE`) for co-occurrence display in the UI. Data is computed from 2+ kills.

### Shared Slot Detection

**What it does**: Identifies pairs of items that likely share a drop slot (mutually exclusive drops).

**Method**: If two items NEVER drop together despite sufficient opportunity, they probably share a slot:
- Both items have >= 5 drops each
- Expected co-occurrence >= 2 (enough opportunity that zero co-occurrence is notable)
- Observed co-occurrence = 0

**Confidence labels**:
- `Very High`: expected co-occurrence >= 5 (strong signal)
- `High`: expected co-occurrence >= 2 (moderate signal)

**Why this works**: Under independence, the probability of zero co-occurrences when expecting 5+ is very low. Two items that never appear together across dozens of kills are almost certainly competing for the same slot.

### Inferred Drop Table (Battlefield Mode)

**What it does**: Groups items into probable drop slots using shared-slot relationships.

**Method**: Union-Find (disjoint set) algorithm:
1. Start with each item in its own group
2. For every shared-slot candidate pair (A, B), merge their groups
3. Result: clusters of items that likely share the same slot

**Why Union-Find and not alternatives**:

| Method | Problem |
|--------|---------|
| **Graph community detection** (Louvain, etc.) | Designed for weighted graphs with partial connectivity. Overkill when the signal is binary (co-occurs or doesn't). |
| **K-means clustering** | Needs a distance metric and pre-specified k. Neither is available here. |
| **Hierarchical clustering** | Could work but adds unnecessary complexity for a binary relationship. |
| **Union-Find** | Perfect fit — the relationship is transitive (if A shares a slot with B and B shares with C, then A/B/C all share a slot). O(n * alpha(n)), practically linear. |

**Output per slot**: Total rate (sum of item rates), guaranteed flag (single item at 95%+), and per-item breakdown sorted by rate.

### Drop Arrival Order

**What it does**: Tracks the order in which items appear in the treasure pool to infer drop table slot positions.

**Insight** *(from Thorny)*: FFXI's server walks its drop table sequentially when calling `DropItems()`. The 0x00D2 packets arrive in the order the server iterates its slots. So if Item A consistently arrives before Item B, A is likely in an earlier slot position.

**Implementation**: The `drop_order` column in the drops table records arrival sequence (0, 1, 2...) per kill. The co-occurrence table shows "A<B (85%)" meaning A arrived before B in 85% of co-occurrences.

**Limitation**: Only available for kills recorded after the `drop_order` migration. Legacy data (drop_order = -1) is excluded.

## What Slot Analysis Does NOT Do

| Approach | Why not |
|----------|---------|
| **Bayesian inference** | Requires prior assumptions about drop rates that we don't have. We'd need to choose priors (uniform? beta?) which adds subjectivity. The frequentist approach (Wilson CI, direct observation) is assumption-free. |
| **Monte Carlo simulation** | Too expensive to run per-frame in a game addon running inside the FFXI client. Would need thousands of iterations per mob per render frame. |
| **Hidden Markov Models** | Drops are independent per-kill, not sequential state transitions. There's no "state" that carries between kills — each kill is a fresh set of independent rolls. |
| **Regression models** | No continuous predictor variables. Drop probability is (as far as we know) a fixed constant per slot, not a function of kill count, time, or other variables. |
| **Hypothesis testing (p-values)** | Deliberately avoided. Users want to know "what is the drop rate?" and "do these items share a slot?", not "is this result statistically significant at alpha=0.05?" The deviation ratio and CI width are more actionable. |

## Distant Kill Exclusion

All Slot Analysis queries filter `is_distant = 0`. Distant kills (drops seen via 0x00D2 without a prior defeat message) have partial drop visibility — you only see items that entered your treasure pool. This makes CI, co-occurrence, and shared-slot inference unreliable because missing drops would create false mutual exclusivity signals.

## Sample Size Considerations

All sections display data from the first kill. Low-sample warnings appear when results may be unreliable:

| Section | Recommended minimum | Why |
|---------|-------------------|-----|
| Confidence Intervals | 30 kills | Wilson CI coverage approaches nominal 95% around n=30 |
| Co-occurrence | 50 kills | Need enough kills for expected co-occurrence counts to be meaningful |
| Shared Slots | Varies | Depends on individual item drop rates — higher rates need fewer kills |
| Slot Estimation | 10+ kills | `max_items_per_kill` stabilizes quickly; rate sum needs more data |

## Credits

- **Thorny** — Slot Analysis concept, drop order tracking idea, and ongoing feedback
