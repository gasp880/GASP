"""Method-only API for caller-supplied CAN messages."""

from collections import defaultdict
from dataclasses import replace
from gasp.scheduler import Flow, Packet, GuardPolicy, group_schedule, validate


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
    by_uid = {flow.uid: flow for flow in original}
    if len(by_uid) != len(original):
        raise ValueError("message identifiers must be unique")
    groups = defaultdict(list)
    for flow in original:
        if flow.critical:
            groups[flow.requirement].append(flow)
    required = {}
    for identifier, members in groups.items():
        indexes = tuple(sorted(flow.member for flow in members))
        if len(indexes) != len(set(indexes)):
            raise ValueError("member identifiers must be unique within a group")
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
    validate(restored, original, rate=1, guard=guard)
    return restored
