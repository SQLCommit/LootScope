# Slot analysis

[Back to LootScope](README.md)

How to read the Slot Analysis tab and the methods behind its estimates. These results describe patterns in your recorded kills; they do not reveal the server’s actual drop table.

## The drop model

The analysis starts with a model of **N independent drop slots**, each rolling with its own probability. A four-slot model makes four rolls per kill. Shared slots, conditions, or incomplete observations can depart from this model, so the results are estimates rather than confirmed game mechanics.

## Wilson score confidence intervals

A 95% interval for each item's true drop rate.

| alternative | why not |
|---|---|
| Wald (normal) | unreliable below ~100 trials, and can produce negative bounds |
| Clopper-Pearson | conservative - gives 98-99% coverage where 95% was asked for |
| Agresti-Coull | an approximation of what Wilson does exactly |

Wilson is well behaved at any sample size and any rate. `wilson_ci()` in `analysis.lua`, z=1.96. Reliability badges come from the interval width.

## Poisson binomial distribution

The exact distribution of "how many items drop per kill" under the slot model.

| alternative | why not |
|---|---|
| Binomial | assumes every trial has the same probability; drop rates differ |
| Poisson | needs large n and small probabilities; FFXI rates run 20-50% |
| Normal | same requirement, same problem |
| Monte Carlo | thousands of iterations per mob, per frame |

Poisson binomial is exact for N independent trials with *different* probabilities. `poisson_binomial_pmf()`, O(n^2) dynamic programming, capped at 30 items.

Comparing the observed items-per-kill histogram against it shows how well the independent slot model fits. Large deviations suggest shared slots or conditional drops.

## Slot count estimation

- **Floor** - the most items ever seen from a single kill
- **Rate sum** - `ceil(sum of all rates)`; a sum above 1.0 proves multiple slots
- **Estimate** - the larger of the two

**Empty kill fit** compares the observed empty-kill rate against `product of (1 - p)`. Agreement is consistent with the model; disagreement can reflect shared slots, conditions, or incomplete data.

## Co-occurrence

For each pair: `expected = P(A) * P(B) * kills`, and `deviation = observed / expected`.

| deviation | meaning |
|---|---|
| ~1.0 | independent - separate slots |
| < 1.0 | mutually exclusive - likely sharing a slot |
| > 1.0 | positively correlated - conditional or linked drops |

A ratio rather than chi-squared or Fisher's exact, because those give a p-value instead of a magnitude. "These appear together a fifth as often as expected" needs no statistical training to read.

Shown at 5+ drops per item and 50+ kills.

## Shared slot detection

Two items that never drop together despite the opportunity probably compete for one slot. Requires 5+ drops each, expected co-occurrence of 2 or more, and observed co-occurrence of zero. Labelled **High**, or **Very High** once expected reaches 5.

## Inferred drop table (battlefield mode)

Union-Find over the shared-slot pairs: every item starts alone, each candidate pair merges its groups. This grouping is transitive: links from A to B and B to C place all three together. That is a grouping rule, not proof that every pair competes for the same server-side slot. Graph community detection and k-means both need inputs this data does not have (edge weights, a distance metric, a chosen k).

Per group: total rate and its items, sorted by rate. The UI marks a single item observed at 95%+ as guaranteed; this threshold is a display heuristic, not proof of a guaranteed drop.

## Drop arrival order

*(insight from Thorny)* Recorded pool-packet arrival order provides another clue: if A consistently arrives before B, the analysis treats A as a candidate for an earlier slot. Arrival order alone does not establish the server’s slot order.

`drop_order` records the sequence per kill, and the co-occurrence table shows `A<B (85%)`. Only available for kills recorded after the column was added.

## Distant kills

Excluded everywhere (`is_distant = 0`). You see only the items that reached your own pool, and the missing ones would read as false mutual exclusivity.

## Sample size

Everything displays from the first kill, with a warning while the sample is thin.

| section | useful from |
|---|---|
| Confidence intervals | 30 kills |
| Co-occurrence | 50 kills |
| Slot estimation | 10 kills |
| Shared slots | varies with drop rate |

## Credits

- **Thorny** - Slot Analysis concept, drop order tracking idea, and ongoing feedback
