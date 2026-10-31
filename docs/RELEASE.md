# Release scope

The current public release includes the GASP scheduling method, hand-written
API and manuscript examples, a GitHub Actions runner for the manuscript example,
deterministic method tests, experiment-setting descriptions, and FPGA
implementation sources. Full experimental scripts will be released upon
paper acceptance.

The current release excludes random workload generation, comparison/ablation
drivers, batch execution, checkpoint/resume, statistical aggregation, result
export/plotting, FPGA case generation, host measurement and replay scripts,
sampled experiment configurations, captured data and previously generated
experimental results. The constructed manuscript example computes its own
small illustrative schedule when run.

[PAPER_VERSION.md](PAPER_VERSION.md) fixes the method commit and code hashes.
[FPGA.md](FPGA.md) documents the RTL capacities and API-to-hardware field
mapping; host loading and experimental replay scripts remain outside this
release.

`SOURCE_MANIFEST.json` lists every distributed file and its SHA-256 hash.
Run `python3 scripts/verify_sources.py`; use `--strict` for a clean source
checkout to reject extra unlisted files. Local caches and generated build
products are excluded from Git.

No software license grant has been added. Licensing terms are to be selected
by the authors. Existing third-party notices retain their meaning.
