"""Method-only API for caller-supplied CAN messages."""

from collections import defaultdict
from dataclasses import replace
from gasp.scheduler import (
    Flow, Packet, GuardPolicy, group_schedule, validate, _pairwise_harmonic,
)


def _checked_inputs(flows):
    """Check the fixed five-domain input contract before allocating frames."""
    by_uid = {}
    groups = defaultdict(list)
    noncritical_ids = set()
    for flow in flows:
        if not isinstance(flow, Flow):
            raise ValueError("each message must be a Flow")
        if not isinstance(flow.uid, str) or not flow.uid or flow.uid in by_uid:
            raise ValueError("message identifiers must be nonempty and unique")
        by_uid[flow.uid] = flow
        ranges = {
            "requirement": (0, None), "member": (0, None),
            "source": (0, 4), "destination": (0, 4),
            "period": (1, None), "deadline": (1, None),
            "payload": (0, 8), "priority": (0, 2047),
        }
        for field, (low, high) in ranges.items():
            value = getattr(flow, field)
            if (not isinstance(value, int) or isinstance(value, bool)
                    or value < low or (high is not None and value > high)):
                raise ValueError(f"{flow.uid}: invalid {field}")
        if flow.source == flow.destination:
            raise ValueError(f"{flow.uid}: source and destination must differ")
        levels = ("A", "B", "C", "D", "QM")
        if flow.parent not in levels or flow.asil not in levels:
            raise ValueError(f"{flow.uid}: unknown ASIL class")
        if (flow.parent == "QM") != (flow.asil == "QM"):
            raise ValueError(f"{flow.uid}: parent and member traffic classes differ")
        if flow.critical:
            groups[flow.requirement].append(flow)
        else:
            if flow.requirement in noncritical_ids:
                raise ValueError("non-critical messages need distinct requirement identifiers")
            noncritical_ids.add(flow.requirement)
    if noncritical_ids.intersection(groups):
        raise ValueError("critical groups and non-critical messages need distinct identifiers")
    for members in groups.values():
        indexes = [flow.member for flow in members]
        if len(indexes) != len(set(indexes)):
            raise ValueError("member identifiers must be unique within a group")
        attributes = {
            (flow.parent, flow.period, flow.deadline, flow.payload, flow.destination)
            for flow in members
        }
        if len(attributes) != 1:
            raise ValueError("group members must share parent, period, deadline, payload and destination")
    return by_uid, groups


def _check_group_result(result, original, groups, guard):
    """Validate timing and the method's packing/admission contract explicitly."""
    accepted = validate(result, original, rate=1, guard=guard)
    for packet, _ in result:
        if len({flow.critical for flow in packet.flows}) != 1:
            raise RuntimeError("GASP mixed critical and non-critical messages")
        if not _pairwise_harmonic([flow.period for flow in packet.flows]):
            raise RuntimeError("GASP packed nonharmonic periods")
        identifiers = [flow.requirement for flow in packet.flows if flow.critical]
        if len(identifiers) != len(set(identifiers)):
            raise RuntimeError("GASP co-packed members of a critical group")
    for members in groups.values():
        identifiers = {flow.uid for flow in members}
        admitted = identifiers.intersection(accepted)
        if admitted and admitted != identifiers:
            raise RuntimeError("GASP partially admitted a critical group")


def schedule(flows, *, guard_ticks=12336):
    """Schedule fixed groups, then non-critical messages, on a 10 ns grid.

    All members of a critical requirement are admitted together in distinct
    frames. Input order determines the first member used for group-priority
    ties. No workload generation or experimental statistics are performed.
    """
    original = tuple(flows)
    if (
        not isinstance(guard_ticks, int)
        or isinstance(guard_ticks, bool)
        or guard_ticks < 0
    ):
        raise ValueError("guard_ticks must be a nonnegative integer")
    by_uid, groups = _checked_inputs(original)
    required = {}
    for identifier, members in groups.items():
        indexes = tuple(sorted(flow.member for flow in members))
        required[identifier] = (indexes,)
    view = tuple(
        (
            replace(flow, success_sets=required[flow.requirement])
            if flow.critical
            else flow
        )
        for flow in original
    )
    guard = GuardPolicy(width=guard_ticks, mode="gate")
    result = group_schedule(
        view,
        rate=1,
        guard=guard,
        aggregate=True,
        harmonic=True,
        member_order="priority",
        payload_cap=1500,
    )
    restored = [
        (Packet(tuple(by_uid[flow.uid] for flow in packet.flows)), offset)
        for packet, offset in result
    ]
    _check_group_result(restored, original, groups, guard)
    return restored
