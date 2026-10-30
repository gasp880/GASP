# GASP method and API

## Inputs

`from gasp import Flow, schedule` exposes the message type and scheduler.
Each `Flow` contains:

| Field | Meaning |
| --- | --- |
| `uid` | Nonempty unique string message identifier |
| `requirement` | Fixed group identifier; use a separate identifier for each non-critical message |
| `parent`, `asil` | Original requirement class and member class; `QM` identifies non-critical messages internally |
| `member` | Distinct nonnegative integer member index within a group |
| `source`, `destination` | Domain indices, 0 through 4 |
| `period`, `deadline` | Positive integer 10 ns ticks |
| `payload` | CAN payload length, 0 through 8 bytes |
| `priority` | Integer CAN identifier, 0 through 2047; lower values rank higher |

Members of an input group share parent class, period, deadline, payload length
and destination. Group identifiers are nonnegative integers. The
input sequence defines the first stored member used for group-priority ties.
The optional internal `success_sets` field is overwritten in the scheduling
view so that a critical group always requires all its supplied members.

`schedule(messages, guard_ticks=12336)` returns a list of `(Packet, offset)`
pairs. Each packet contains its admitted `flows`; offsets use 10 ns ticks.
The fixed link rate is 100 Mbps, equivalent to one bit per tick. The method
does not select or alter an ASIL decomposition configuration.
`Packet.duration()` returns 10 ns ticks by default. Invalid inputs raise
`ValueError`, including out-of-range fields, duplicate identifiers and
inconsistent group attributes. Critical group identifiers and non-critical
message identifiers must be distinct. Timing and group-result checks remain
active under `python -O`. Inputs specify the decomposition; the API does not
certify its ISO 26262 validity or element independence.

## Admission and packing

GASP processes critical groups in deadline order, using the priority of the
first stored member to break ties. Members follow increasing CAN priority.
A temporary copy of the committed schedule is used for each group. Success
for every member commits the copy; failure discards it and proceeds to the
next group. Failed groups are not repaired later.

Each member considers a new frame followed by eligible existing frames in
configuration order. Aggregation requires the same source, destination and
traffic class, pairwise harmonic periods, distinct critical group identifiers,
and at most 1500 bytes of CAN records. Each record adds 8 bytes of overhead.

Every option is checked independently. A modified frame's old reservation is
removed for that trial; its replacement is scheduled against the remaining
reservations. Frame period is the greatest common divisor of member periods;
frame deadline is their minimum. Wire duration includes Ethernet overhead,
minimum-frame padding and IFG. Both hop reservations must finish by the
deadline. Modular conflict checks use period greatest common divisors.

Among feasible options, a new frame adds `C_new/T_new` periodic occupancy;
a merge adds `C_merged/T_merged - C_old/T_old`. The smallest increment is
selected using exact rational arithmetic. Equal increments favor earlier two-hop completion, then preserve
option construction order. Offset search returns the earliest feasible tick.
Non-critical messages use remaining slots in deadline/priority order.

The non-critical start guard is 12336 ticks (123.36 microseconds). There is
no additional critical-to-critical guard. See `gasp/api.py` for the method
profile and `gasp/scheduler.py` for the scheduling primitives.
