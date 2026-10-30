# Experimental settings

## Network and traffic

The generator uses the General Motors class proportions reported in the reference literature. The present release records the sampling parameters; workload-generation scripts are deferred until acceptance.

| Attribute | Setting |
| --- | --- |
| Network | Five domains and one central switch; directed 100 Mbps uplinks and downlinks |
| Time grid | 10 ns |
| Period | Uniform over 10, 20, 50, 100 ms |
| Relative deadline | Uniform over 100, 300, 500, 700 microseconds |
| CAN payload | Uniform integer from 0 through 8 B |
| Encapsulation | 8 B per CAN record |
| Source and destination | One uniform destination per group; each member independently selects a different domain as its source |
| Priorities | Unique randomly assigned 11-bit CAN identifiers; lower values have higher priority |
| Members of a group | Share period, deadline, and payload length |
| Configuration | Uniform selection from the critical-only configuration catalog, including the unchanged level |
| Critical aggregation limit | GASP/SPS: 1500 B of records; EMSO: 750 B |
| MSOA time targets | Maximum-payload frame time divided by 4, 2, and 8 for initial packing, merging, and regrouping |
| Non-critical start guard | 123.36 microseconds = 12336 ticks; no additional critical-to-critical guard |

At 100 Mbps, each tick transports one bit. For a frame whose records total `B` bytes, the per-hop reservation is `8 * (20 + max(64, 22 + B))` ticks. The formula includes preamble/SFD, tagged MAC header, FCS, padding, and IFG. The deadline check requires both hop reservations to finish by the frame deadline. Domain-side CAN arbitration and forwarding are not simulated.

## Evaluation grids

1. **Requirement count:** 50 through 600, step 50. Class weights are
   D:C:B:A:QM = 8:4:6:5:4. Counts refer to requirements before decomposition.
2. **Non-critical load:** 50, 150, or 300 critical requirements, all ASIL-D
   before decomposition; 50 through 600 non-critical messages, step 50.
   Each case selects nested prefixes from a fixed pool of 300 critical
   requirements and 600 non-critical messages.

Both grids use seeds 2000 through 2099 and identical inputs across methods
within a condition and seed. Software evaluation computes static periodic
schedules. The parameter file is descriptive; batch execution, comparison
implementations and analysis scripts are not included in this release.

The primary comparison uses R-NWTT, S-EMSO, S-MSOA, SPS, SMP and GASP.
S-EMSO/S-MSOA add same-group frame separation at all aggregation stages of
EMSO/MSOA while retaining their other packing, scheduling and message-level
admission rules. Original EMSO/MSOA are separate diagnostic comparisons.
`settings/experiments.json` records both profiles explicitly. GASP/SPS compare
additional periodic occupancy using exact rational arithmetic.

## Evaluation quantities

| Paper quantity | Generated field / computation |
| --- | --- |
| Isolated group acceptance | `isolated_group_acceptance`: all members scheduled in distinct frames, divided by all input critical groups, including singletons |
| Non-critical message acceptance | `qm_acceptance`: accepted non-critical CAN messages divided by input non-critical CAN messages |
| Periodic occupancy saving | `matched_wire_saving`: `1 - packed/single`, using the same admitted critical and non-critical messages for that method |
| Complete multi-member groups | `complete_redundant_groups` |
| Complete and frame-isolated multi-member groups | `isolated_complete_redundant_groups` |
| Input critical groups / input multi-member groups | `critical_groups` / `redundant_groups` |

Occupancy uses the sum of `C/T` over scheduled frames, excluding idle guard bands. Individual packing of the same admitted messages provides the denominator. Different methods can admit different message sets. Ratios are calculated per seed before arithmetic averaging; undefined ratios remain null and valid sample counts are retained.

To reconstruct the pooled four-state distribution, sum these counts over cases and divide by the summed input critical group counts:

- Fully admitted and isolated: `complete_critical_groups - complete_redundant_groups + isolated_complete_redundant_groups`.
- Fully admitted but co-packed: `complete_redundant_groups - isolated_complete_redundant_groups`.
- Partially admitted: `orphan_groups` minus the fully admitted but co-packed count, under the all-member profile.
- None admitted: the remaining input critical groups.

