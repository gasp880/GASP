# FPGA implementation scope

The ZCU104 design contains five logical gateways and a central switching
module. Internal byte-bearing links are timed at 100 Mbps using a 100 MHz
operational clock (10 ns ticks; eight ticks per byte). The board's 125 MHz
differential clock is converted to 100 MHz by the clock IP.

Gateways execute supplied frame templates, offsets, periods and member
metadata. A shared start defines tick zero. Member-specific counters update
release instance numbers and payload bytes, and frame FCS is recomputed during
execution. The receiving monitor checks bytes, identifiers, instances and
deadlines. Repeated records do not add accepted instances.

Included sources:

- `hardware/fpga/rtl/`: gateways, switch, executor and reception monitor.
- `hardware/common/`: shared network types and frame buffer.
- `hardware/fpga/constraints/`: ZCU104 physical constraints.
- `hardware/fpga/vivado/`: block design and synthesis/implementation files.

Vivado 2025.2 with ZCU104 support is required for hardware construction.
`create_project.tcl` recreates the block design; `build.tcl` performs synthesis,
implementation and timing/route/DRC checks. Generated projects and bitstreams
are not distributed. These files describe an internal FPGA datapath; five
external Ethernet PHYs or CAN buses are not connected by this prototype.

The compact RTL supports 36 frame slots per source port, 288 MAC bytes per
slot, eight period banks, 640 group identifiers and 1024 release epochs.
These implementation capacities differ from the software's 1500-byte CAN
record aggregation limit. The paper settings specify 100 hyperperiods,
or 10 seconds for the documented periods, per measured configuration.

Workload/configuration generation, host loading, batch replay, measurement,
testbench orchestration and experimental outputs are deferred until acceptance.
