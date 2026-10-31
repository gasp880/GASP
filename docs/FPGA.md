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

## Capacity envelope

| Resource | Current RTL limit |
| --- | --- |
| Logical source/destination ports | 5, numbered 0–4 |
| Frame slots | 36 per source, 180 total |
| MAC template length | 64–288 B per frame, including header, padding and FCS |
| Member-period banks | 8 distinct scheduled-member periods |
| Period and hyperperiod | At most 10,000,000 ticks (100 ms) |
| Group identifiers | 0–639 |
| Members per group | At most 4, numbered 1–4 on the wire |
| Monitored release epochs | 0–1023 per member |
| Run window | Positive 31-bit tick count, at most 2,147,483,647 |
| Hyperperiod snapshots | 128 |

The software's 1500-byte CAN record aggregation limit is independent of the
288-byte hardware MAC template limit. A software schedule must fit all RTL
limits before loading; hardware loading preserves its packing and offsets.
The paper settings specify 100 hyperperiods, or 10 seconds for the documented
periods, per measured configuration.

An audit of the five saved 200–600-requirement hardware configurations found
that all fit this envelope. Across those configurations, the largest use was
35 frame slots at one source, 265 MAC bytes in one frame, four member-period
banks, group identifier 599, member identifier 4 and release epoch 999.
Each window contains 1,000,000,000 ticks and 100 snapshots. Comparing the saved
2-hyperperiod and 100-hyperperiod inputs confirmed identical frame templates,
member metadata, packed slots and periods. This was a check of existing
configuration files; no new hardware run was required.

## Mapping a method result to RTL fields

For a `(Packet, offset)` returned by `gasp.schedule`, retain its route, member
assignments, period, deadline and offset. The following mapping describes the
current hardware interface.

| API value | Hardware representation |
| --- | --- |
| `Packet.route` | Zero-based source and destination ports |
| Frame index `j` within source `s` | Global slot `s * 36 + j`, with `0 <= j < 36` |
| `Packet.payload` | Record bytes `B = sum(flow.payload + 8)` |
| MAC template length | `L = max(64, 22 + B)` bytes |
| `Packet.duration()` | `C = 8 * (L + 20)` ticks per hop |
| Returned `offset` | Uplink starts at `offset`; downlink starts at `offset + C` |
| `Packet.period` | Greatest common divisor of member periods |
| `Packet.deadline` | Minimum member deadline |
| Frame flags | Destination in bits 2:0; critical in bit 8; refresh FCS in bit 9 |
| `Flow.requirement` | Group identifier, retained if within 0–639 |
| `Flow.member` | Wire member `member + 1` for contiguous API indices 0–3 |
| `Flow.asil` | One byte: QM=0, A=1, B=2, C=3, D=4 |

The API permits arbitrary nonnegative group and member indices. For more
general caller inputs, an adapter must assign distinct group identifiers
within 0–639 and distinct member identifiers within 1–4 per group, preserving
a reversible mapping. Reject configurations with more groups or members than
the RTL supports.

The MAC template starts with an 18-byte tagged Ethernet header. Each record
then contains an 8-byte big-endian header followed by its CAN payload:

| Record offset | Field |
| --- | --- |
| 0–1 | Group identifier, 16 bits |
| 2 | Wire member identifier |
| 3 | ASIL byte |
| 4–5 | CAN payload length, 16 bits |
| 6–7 | Release epoch, 16 bits |
| 8 onward | CAN payload, 0–8 B |

The first record starts at MAC byte 18; each following record advances by
`8 + payload_length` bytes. Pad the MAC content to at least 60 bytes and append
the four-byte Ethernet FCS. The extra 20 bytes used in `C` account for
preamble/SFD and IFG and are not stored in the MAC template.

Each template RAM entry is a 13-bit word: bits 7:0 hold the byte, bits 10:8
select a member-period bank, and bits 12:11 select the update mode:

| Mode | Emitted value |
| --- | --- |
| 0 | Static template byte |
| 1 | High byte of the selected member's release epoch |
| 2 | Low byte of the selected member's release epoch |
| 3 | `(base_payload_byte + release_epoch) mod 256` |

Use modes 1 and 2 at record offsets 6 and 7, and mode 3 for the prototype's
test payload bytes. Use mode 0 elsewhere. Populate banks with the distinct
scheduled-member periods, including slower periods in an aggregated frame;
the frame's GCD period alone does not identify each member's release epoch.
The RTL refreshes the FCS after byte updates.

## Reception-monitor descriptors

Provide one descriptor for every input member, including members with no
scheduled frame. The descriptor key is `group * 4 + wire_member - 1`.

| Descriptor word | Content |
| --- | --- |
| 0 | Present bit 0; critical bit 1; location count in bits 3:2; destination in bits 6:4; payload length in bits 11:8; frame slot in bits 23:16; record ASIL byte in bits 31:24 |
| 1 | Member period in ticks |
| 2 | Member deadline in ticks |
| 3–4 | Up to 8 base payload bytes in two little-endian words, zero-padded |

A scheduled member has one location. An unscheduled member uses location
count 0, slot 255 and destination 7, and remains present in the input set.
The monitor matches group/member/epoch, checks the first valid arrival
against the member deadline and deduplicates repeated records.

## Configuration register addresses

Addresses below are byte offsets from the executor's AXI base. Configure
while stopped, using aligned 32-bit writes. Frame registers are staged;
writing enable 1 commits the selected slot. Monitor addresses include its
`0x100` offset inside the executor.

| Address | Field |
| --- | --- |
| `0x10` | Run-window tick count |
| `0x40` | Global frame slot selector |
| `0x44` | Frame flags |
| `0x48`, `0x4C`, `0x50` | Frame period, offset and deadline |
| `0x54`, `0x58` | MAC length and slot enable |
| `0x60` | Template byte index |
| `0x64` | Template word at selected byte |
| `0x68` | Template word with byte-index auto-increment |
| `0x70`, `0x74` | Member-period bank selector and period |
| `0xC0` | Hyperperiod tick count |
| `0x104` | Monitor command: 1 clears descriptors; 2 commits them |
| `0x10C` | Monitor member key |
| `0x110`, `0x114` | Descriptor word index (0–4) and data |

The source definitions are
[`board_executor_axi.vhd`](../hardware/fpga/rtl/board_executor_axi.vhd),
[`board_network.vhd`](../hardware/fpga/rtl/board_network.vhd) and
[`gasp_metric_monitor.vhd`](../hardware/fpga/rtl/gasp_metric_monitor.vhd).

Workload/configuration generation, host loading, batch replay, measurement,
testbench orchestration and experimental outputs are deferred until acceptance.
