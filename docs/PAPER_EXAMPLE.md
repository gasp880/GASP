# Run the paper example

This example implements the manuscript's eight-requirement table and packing
and scheduling illustration. It uses 12 explicitly specified CAN messages,
calls the public GASP implementation, and computes the output at run time.
It has no random workload generation or performance-experiment driver.

## Run locally

Use Python 3.13. From the repository root:

```bash
python3 -m examples.paper_example
```

The output contains the input table, the three packing trials for the second
B-level member of group 3, and the final five-frame schedule. It reports both
hop reservations, deadlines, member assignments and whole-group admission.
Built-in checks compare these decisions with the numerical example in the
manuscript and exit with an error if they differ.

To plot the frame contents and reservations on each uplink and the shared
downlink, install the optional plotting dependency and run:

```bash
python3 -m pip install -r examples/requirements-visualization.txt
python3 -m examples.visualize_paper_example --output-dir example-figures
```

This computes the schedule again and exports PNG, editable SVG, PDF and a
JSON record of the plotted frame assignments and timings. The plot shows the
first release of the 40 ms streams. Plotting support is optional; the method
and text-only example still use only the Python standard library.

## Run on GitHub

Open **Actions → Paper example** and select a completed run. Its **Summary**
displays the computed tables; the **Run paper example** step contains the
same output in its logs. The workflow runs on source pushes and also supports
**Run workflow** for repository users with write access. Readers can view
completed public runs without executing code locally; to start their own
GitHub run, they can fork the repository and enable Actions.

Each run also generates **paper-example-figures**, available under its
**Artifacts** section and through the download link in the Summary. GitHub
requires a signed-in account to download Actions artifacts. The inline Summary
and README preview use the versioned image of the same verified hand-written
example; the artifact contains the files generated during that run. Artifacts
are retained for 90 days; the README preview remains part of the repository.

## Input conventions

The manuscript uses domains 1–5 and member superscripts starting at 1.
The Python API uses domains 0–4 and zero-based member indices. The example
converts these explicitly and displays the manuscript's domain numbers.
All members have period 40 ms. The payload column below excludes the 8-byte
CAN record header.

| Group | Member classes | Source domains | Destination | Payload (B) | Deadline (us) | CAN priorities |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | D | 1 | 5 | 8 | 22 | 1 |
| 2 | C, A | 1, 1 | 5 | 8 | 26 | 2, 3 |
| 3 | B, B | 3, 1 | 5 | 0 | 36 | 4, 5 |
| 4 | B, A, A | 1, 3, 4 | 5 | 8 | 42 | 6, 7, 8 |
| 5 | QM | 2 | 5 | 8 | 70 | 9 |
| 6 | QM | 2 | 5 | 0 | 70 | 10 |
| 7 | D | 1 | 5 | 8 | 24 | 11 |
| 8 | D | 1 | 5 | 8 | 25 | 12 |

Groups 1–4, 7 and 8 have ASIL-D parent requirements. Groups 5 and 6 are
non-critical messages. Frame labels follow the illustration, including `f6`
for the unselected new-frame candidate. Final frame parameters can differ
from trial-time parameters after later cross-group merges.
