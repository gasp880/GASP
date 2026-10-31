# Paper method version

The GASP method corresponding to the current manuscript is fixed at commit
[`a9135bce8abd75bd6e34a47baeef689f0e8e4764`](https://github.com/gasp880/GASP/commit/a9135bce8abd75bd6e34a47baeef689f0e8e4764).
Subsequent documentation, settings-catalog and hand-written example additions
retain the following method files unchanged:

| Method file | SHA-256 |
| --- | --- |
| `gasp/api.py` | `48305d13eed70f3d835340de4c833049cf6b5d2effc4bed0a069a483451611a8` |
| `gasp/scheduler.py` | `fee2beb3afcb65e610a932c126596ad7b03726123050a820925cffa20fbbafc7` |
| `gasp/serialization.py` | `eadb9eec735e42e21c0d7097d258642d78504444966c9ee0ceaeb5a88177ad73` |

The public scheduler shares the packing, guard, periodic-conflict, offset-search
and group-admission function bodies used by the experiment implementation.
The public API fixes the all-member admission profile and validates its inputs
and returned schedule. Source comparison and bounded output-equivalence checks
were completed when preparing this release. This correspondence covers the
GASP method; the batch experiment drivers and comparison implementations are
outside the present release.

The complete distributed-file hashes are in `SOURCE_MANIFEST.json`. From a
clean checkout, run:

```bash
python3 scripts/verify_sources.py --strict
```

The [paper example](PAPER_EXAMPLE.md) executes this method on the small,
hand-written input in the manuscript. See [release scope](RELEASE.md) for the
contents of the current source release.
