# GASP: Group-Aware Scheduling and Packing

This repository provides the GASP method implementation, experimental settings,
and FPGA RTL with project construction files for the accompanying study.

**Release status:** Full experimental scripts will be released upon paper
acceptance. The present release contains no software experiment drivers,
comparison/ablation runs, random workload generators, statistical exports,
FPGA batch replay or measurement scripts, or previously generated results.

## Layout

```text
gasp/       GASP algorithm, message/frame types, wire timing and method API
settings/   Network, traffic, ASIL configuration and evaluation parameters
hardware/   FPGA RTL, constraints and Vivado project construction
examples/   One small hand-written method example
tests/      Deterministic method and input-validation checks
docs/       Method and experimental-setting descriptions
scripts/    Distributed source-integrity check
```

## Use the method

Python 3.13 and its standard library are sufficient. From the repository root:

```bash
python3 scripts/verify_sources.py
python3 -m unittest discover -s tests -v
python3 -O -m unittest discover -s tests -v
python3 -m examples.minimal
```

The example uses a small hand-written input and does not reproduce a paper
experiment. To schedule your own messages, call `gasp.schedule(messages)`.
Time fields and returned offsets use integer 10 ns ticks; payload lengths use
bytes. See [the API and algorithm notes](docs/ALGORITHM.md).
`Packet.duration()` also returns 10 ns ticks by default. The tests use small
hand-written inputs and synthetic certificates; they contain no paper results
or experiment drivers.

Optional installation: `python3 -m pip install -e .`.

## Experimental settings

[settings/experiments.json](settings/experiments.json) records the paper's
network, traffic distributions, method parameters, experiment grids and FPGA
settings. [settings/asil_configurations.json](settings/asil_configurations.json)
lists the input configuration options. These files describe the settings;
they are not executable experiment drivers.

- [Experimental setting and metric definitions](docs/EXPERIMENTAL_SETTINGS.md)
- [FPGA implementation scope](docs/FPGA.md)
- [References](docs/REFERENCES.md)
- [Release contents and licensing status](docs/RELEASE.md)
