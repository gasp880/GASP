"""GASP packing and modular periodic scheduling primitives.

Time values are integer 10 ns ticks. The public schedule() API selects the
paper's all-member admission, harmonic aggregation and padded wire timing.
"""

from __future__ import annotations
from collections import defaultdict
from dataclasses import dataclass
import math
from typing import Sequence
from gasp.serialization import wire_bytes


@dataclass(frozen=True)
class Flow:
    uid: str
    requirement: int
    parent: str
    asil: str
    member: int
    source: int
    destination: int
    period: int
    payload: int
    deadline: int
    priority: int
    success_sets: tuple[tuple[int, ...], ...] = ()

    @property
    def critical(self):
        return self.parent != "QM"


@dataclass(frozen=True)
class Packet:
    flows: tuple[Flow, ...]

    @property
    def critical(self):
        """A mixed PDU inherits the critical class of any contained record."""
        return any(f.critical for f in self.flows)

    @property
    def period(self):
        return math.gcd(*(f.period for f in self.flows))

    @property
    def deadline(self):
        return min(f.deadline for f in self.flows)

    @property
    def priority(self):
        return min(f.priority for f in self.flows)

    @property
    def route(self):
        return self.flows[0].source, self.flows[0].destination

    @property
    def payload(self):
        return sum(f.payload + 8 for f in self.flows)

    @property
    def wire_bytes(self):
        return wire_bytes(self.payload)

    def duration(self, rate=100):
        return math.ceil(8 * self.wire_bytes / rate)


Schedule = list[tuple[Packet, int]]


@dataclass(frozen=True)
class GuardPolicy:
    """Explicit directional gate model; integer guard retains legacy results.

    gate: prohibit QM starts in [TT start-width, TT end), while allowing
    an already-started frame to finish. idle: require that whole interval
    to be free of QM transmissions. Both permit TT-to-QM back-to-back service.
    These are per-TT-window abstractions, not a hardware GCL compiler.
    exclusive: reserve an idle interval before EACH critical PDU, excluding
    both critical and QM transmissions. No critical-window merging. This is
    an explicit paper-inspired convention, not verified author code.
    release_floor: minimum source offset for a critical PDU, measured from
    its periodic release. This consumes deadline budget, not wire duration.
    It is independent of inter-frame guards; default zero preserves history.
    """

    width: int = 120
    mode: str = "gate"
    release_floor: int = 0

    def __post_init__(self):
        if (
            not isinstance(self.release_floor, int)
            or self.release_floor < 0
            or self.width < 0
            or self.mode not in ("gate", "idle", "exclusive")
        ):
            raise ValueError("invalid guard policy")


def _pair_guard(a: Packet, b: Packet, guard: int) -> int:
    """Legacy symmetric cross-class gap; not an exact Yan GCL model."""
    return guard if a.flows[0].critical != b.flows[0].critical else 0


def _gap_after(a: Packet, b: Packet, guard, rate):
    if not isinstance(guard, GuardPolicy):
        return _pair_guard(a, b, guard)
    if guard.mode == "exclusive":
        return guard.width if b.critical else 0
    if a.critical or not b.critical:
        return 0
    return (
        guard.width
        if guard.mode == "idle"
        else max(0, guard.width - a.duration(rate) + 1)
    )


def overlaps(a: Packet, x: int, b: Packet, y: int, rate=100, guard=0) -> bool:
    """Exact infinite-period conflict criterion for half-open intervals."""
    ca, cb = a.duration(rate), b.duration(rate)
    ab, ba = _gap_after(a, b, guard, rate), _gap_after(b, a, guard, rate)
    g = math.gcd(a.period, b.period)
    for hop in (0, 1):
        if a.route[hop] != b.route[hop]:
            continue
        delta = (x + hop * ca - y - hop * cb) % g
        if delta < cb + ba or g - delta < ca + ab:
            return True
    return False


def offset_mask(packet: Packet, schedule: Schedule, rate=100, guard=0) -> int:
    """All feasible integer-tick offsets, computed as periodic forbidden intervals."""
    c = packet.duration(rate)
    limit = min(packet.period - 1, packet.deadline - 2 * c)
    if limit < 0 or c > packet.period:
        return 0
    if isinstance(guard, GuardPolicy) and guard.mode == "exclusive" and packet.critical:
        if c + guard.width > packet.period:
            return 0
    mask = (1 << (limit + 1)) - 1
    if isinstance(guard, GuardPolicy) and packet.critical and guard.release_floor:
        if guard.release_floor > limit:
            return 0
        mask &= ~((1 << guard.release_floor) - 1)
    for old, off in schedule:
        d = old.duration(rate)
        ab = _gap_after(packet, old, guard, rate)
        ba = _gap_after(old, packet, guard, rate)
        g = math.gcd(packet.period, old.period)
        for hop in (0, 1):
            if packet.route[hop] != old.route[hop]:
                continue
            if c + d + ab + ba - 1 >= g:
                return 0
            center = off + hop * d - hop * c
            low, high = center - c - ab + 1, center + d + ba - 1
            first = math.ceil(-high / g)
            last = (limit - low) // g
            for repeat in range(first, last + 1):
                lo, hi = max(0, low + repeat * g), min(limit, high + repeat * g)
                mask &= ~(((1 << (hi - lo + 1)) - 1) << lo)
            if not mask:
                return 0
    return mask


def find_offset(packet, schedule, rate=100, guard=0):
    bits = offset_mask(packet, schedule, rate, guard)
    return (bits & -bits).bit_length() - 1 if bits else None


def validate(schedule: Schedule, workload: Sequence[Flow], rate=100, guard=0):
    """Independent pairwise modular validator; raises on any invalid certificate."""
    known = {f.uid: f for f in workload}
    seen = set()
    for j, (p, off) in enumerate(schedule):
        assert p.flows and p.payload <= 1500
        assert len({(f.source, f.destination) for f in p.flows}) == 1
        # Explicit policies use Packet.critical for mixed PDUs; retain the
        # historical homogeneous-only contract for legacy integer guards.
        if not isinstance(guard, GuardPolicy) and guard:
            assert len({f.critical for f in p.flows}) == 1
        assert p.route[0] != p.route[1]
        assert all(f.period > 0 and 0 <= f.payload <= 8 for f in p.flows)
        assert 0 <= off < p.period and off + 2 * p.duration(rate) <= p.deadline
        if isinstance(guard, GuardPolicy) and p.critical:
            assert (
                off >= guard.release_floor
            ), "critical offset precedes release guard floor"
        assert p.duration(rate) <= p.period
        if isinstance(guard, GuardPolicy) and guard.mode == "exclusive" and p.critical:
            assert p.duration(rate) + guard.width <= p.period
        for f in p.flows:
            assert f.uid in known and known[f.uid] == f and f.uid not in seen
            seen.add(f.uid)
        for q, old in schedule[:j]:
            assert not overlaps(p, off, q, old, rate, guard)
    return seen


def _pairwise_harmonic(periods):
    return all(max(a, b) % min(a, b) == 0 for a in periods for b in periods)


def add_flow(flow, schedule, rate, guard, aggregate, harmonic=False, payload_cap=750):
    """Transactional candidate insertion; moving a packet rechecks all conflicts."""
    options = []
    singleton = Packet((flow,))
    if singleton.payload > payload_cap:
        return None
    off = find_offset(singleton, schedule, rate, guard)
    if off is not None:
        options.append(
            (
                singleton.duration(rate) / singleton.period,
                off + 2 * singleton.duration(rate),
                schedule + [(singleton, off)],
            )
        )
    if aggregate:
        for i, (p, _) in enumerate(schedule):
            periods_ok = (
                _pairwise_harmonic([f.period for f in p.flows] + [flow.period])
                if harmonic
                else p.period == flow.period
            )
            if (
                p.route != (flow.source, flow.destination)
                or not periods_ok
                or p.flows[0].critical != flow.critical
                or any(f.requirement == flow.requirement for f in p.flows)
            ):
                continue
            joined = Packet(p.flows + (flow,))
            if joined.payload > payload_cap:
                continue
            remainder = schedule[:i] + schedule[i + 1 :]
            offset = find_offset(joined, remainder, rate, guard)
            if offset is not None:
                options.append(
                    (
                        (
                            (joined.duration(rate) - p.duration(rate)) / p.period
                            if joined.period == p.period
                            else joined.duration(rate) / joined.period
                            - p.duration(rate) / p.period
                        ),
                        offset + 2 * joined.duration(rate),
                        remainder + [(joined, offset)],
                    )
                )
    return min(options, key=lambda x: x[:2]) if options else None


def group_schedule(
    flows,
    rate=100,
    guard=0,
    aggregate=True,
    harmonic=False,
    member_order="index",
    payload_cap=750,
):
    if member_order not in ("index", "priority"):
        raise ValueError("unknown member order")
    requirements = defaultdict(list)
    for f in flows:
        if f.critical:
            requirements[f.requirement].append(f)
    schedule = []
    for members in sorted(
        requirements.values(), key=lambda fs: (fs[0].deadline, fs[0].priority)
    ):
        by_member = {f.member: f for f in members}
        options = []
        for required in members[0].success_sets:
            trial = schedule[:]
            incremental_cost, completion = 0.0, 0
            insertion_order = (
                sorted(required, key=lambda j: by_member[j].priority)
                if member_order == "priority"
                else required
            )
            for member in insertion_order:
                added = add_flow(
                    by_member[member],
                    trial,
                    rate,
                    guard,
                    aggregate,
                    harmonic,
                    payload_cap=payload_cap,
                )
                if added is None:
                    break
                cost, end, trial = added
                incremental_cost += cost
                completion = max(completion, end)
            else:
                options.append((incremental_cost, completion, required, trial))
        if options:
            schedule = min(options, key=lambda x: x[:3])[3]
    # QM receives the remaining slots; never displaces a committed contract.
    for f in sorted(
        (f for f in flows if not f.critical), key=lambda f: (f.deadline, f.priority)
    ):
        added = add_flow(
            f, schedule, rate, guard, aggregate, harmonic, payload_cap=payload_cap
        )
        if added is not None:
            schedule = added[2]
    return schedule
