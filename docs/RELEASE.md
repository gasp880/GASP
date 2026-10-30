# Release scope

The current public release includes the GASP scheduling method, a small
hand-written API example, deterministic method tests, experiment-setting descriptions, and FPGA
implementation sources. Full experimental scripts will be released upon
paper acceptance.

The current release excludes random workload generation, comparison/ablation
drivers, batch execution, checkpoint/resume, statistical aggregation, result
export/plotting, FPGA case generation, host measurement and replay scripts,
paper configurations, captured data and previously generated results.

`SOURCE_MANIFEST.json` lists every distributed file and its SHA-256 hash.
Run `python3 scripts/verify_sources.py`; use `--strict` for a clean source
checkout to reject extra unlisted files. Local caches and generated build
products are excluded from Git.

No software license grant has been added. Licensing terms are to be selected
by the authors. Existing third-party notices retain their meaning.
