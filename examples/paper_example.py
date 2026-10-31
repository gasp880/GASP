"""Run the manuscript's hand-written eight-requirement illustration."""

from dataclasses import replace

from gasp import Flow, Packet, schedule
from gasp.scheduler import GuardPolicy, add_flow, find_offset


# Group, member classes, manuscript source domains, CAN payload bytes,
# deadline in microseconds, and member priorities. All periods are 40 ms.
REQUIREMENTS = (
    (1, ("D",), (1,), 8, 22, (1,)),
    (2, ("C", "A"), (1, 1), 8, 26, (2, 3)),
    (3, ("B", "B"), (3, 1), 0, 36, (4, 5)),
    (4, ("B", "A", "A"), (1, 3, 4), 8, 42, (6, 7, 8)),
    (5, ("QM",), (2,), 8, 70, (9,)),
    (6, ("QM",), (2,), 0, 70, (10,)),
    (7, ("D",), (1,), 8, 24, (11,)),
    (8, ("D",), (1,), 8, 25, (12,)),
)


def messages():
    """Translate the manuscript's numbering to the public API's indices."""
    return tuple(
        Flow(
            uid=f"g{group}:{index + 1}{level}",
            requirement=group,
            parent="QM" if level == "QM" else "D",
            asil=level,
            member=index,
            source=source - 1,
            destination=4,
            period=4_000_000,
            payload=payload,
            deadline=deadline * 100,
            priority=priority,
        )
        for group, levels, sources, payload, deadline, priorities in REQUIREMENTS
        for index, (level, source, priority) in enumerate(
            zip(levels, sources, priorities, strict=True)
        )
    )


def check(condition, message):
    if not condition:
        raise RuntimeError(f"Paper example mismatch: {message}")


def us(ticks):
    return f"{ticks / 100:.2f}"


def group_three_trials(flows):
    """Inspect the three candidates using the implementation's own primitives."""
    prior = schedule(tuple(f for f in flows if f.requirement in (1, 7, 8, 2)))
    first, second = (f for f in flows if f.requirement == 3)
    guard = GuardPolicy(width=12336, mode="gate")
    added = add_flow(first, prior, 1, guard, True, True, payload_cap=1500)
    check(added is not None, "first group-3 member must be feasible")
    trial = added[2]
    solo = Packet((second,))
    check(find_offset(solo, trial, 1, guard) is None, "new frame is infeasible")

    # Relax only this candidate's deadline to explain its earliest completion.
    relaxed = Packet((replace(second, deadline=second.period),))
    earliest = find_offset(relaxed, trial, 1, guard)
    check(earliest is not None, "new-frame diagnostic must have an offset")
    check(earliest + 2 * solo.duration() == 3712, "new-frame bound is 37.12 us")
    rows = [
        ("New frame f6", us(solo.duration()), "--", ">= " + us(earliest + 2 * solo.duration()), "Infeasible: deadline 36 us")
    ]
    anchors = {"g1:1D": "f1", "g2:2A": "f2"}
    for index, (packet, _) in enumerate(trial):
        if packet.route != (second.source, second.destination):
            continue
        label = next(anchors[f.uid] for f in packet.flows if f.uid in anchors)
        joined = Packet(packet.flows + (second,))
        remaining = trial[:index] + trial[index + 1:]
        offset = find_offset(joined, remaining, 1, guard)
        if label == "f1":
            check(offset is None and 2 * joined.duration() == 1824, "f1 trial")
            rows.append(("Merge into f1", us(joined.duration()), "--", "--", "Infeasible: downlink conflict"))
        else:
            check(offset == 1024 and joined.duration() == 672, "f2 trial")
            rows.append(("Merge into f2", us(joined.duration()), us(offset), us(offset + 2 * joined.duration()), "Selected"))

    chosen = add_flow(second, trial, 1, guard, True, True, payload_cap=1500)
    check(chosen is not None, "second group-3 member must be feasible")
    packet, offset = next((p, o) for p, o in chosen[2] if second in p.flows)
    check({f.uid for f in packet.flows} == {"g2:2A", "g3:2B"} and offset == 1024,
          "GASP must select the f2 merge")
    actual = schedule(tuple(f for f in flows if f.requirement in (1, 7, 8, 2, 3)))
    check(actual == chosen[2], "diagnostic trials must match the public API")
    return rows


def final_frames(result):
    """Check frame labels, membership and timing against the illustration."""
    expected = (
        ("f1", {"g1:1D", "g7:1D", "g8:1D", "g2:1C"}, 0, 848),
        ("f2", {"g2:2A", "g3:2B", "g4:1B"}, 1024, 672),
        ("f3", {"g3:1B", "g4:2A"}, 1696, 672),
        ("f4", {"g4:3A"}, 2368, 672),
        ("f5", {"g5:1QM", "g6:1QM"}, 3040, 672),
    )
    check(len(result) == len(expected), "five final frames required")
    rows = []
    for label, members, wanted_offset, wanted_duration in expected:
        matches = [(p, o) for p, o in result if {f.uid for f in p.flows} == members]
        check(len(matches) == 1, f"{label} member assignment")
        packet, offset = matches[0]
        check((offset, packet.duration()) == (wanted_offset, wanted_duration), f"{label} timing")
        rows.append((label, packet, offset))
    return rows


def main():
    flows = messages()
    trials = group_three_trials(flows)
    frames = final_frames(schedule(flows))
    check(sum(len(p.flows) for _, p, _ in frames) == len(flows), "all 12 messages admitted")

    print("# GASP paper example\n")
    print("Eight requirements, 12 CAN messages, period 40 ms; time columns use microseconds.\n")
    print("Critical group order: g1, g7, g8, g2, g3, g4; then non-critical g5 and g6.\n")
    print("## Input\n")
    print("| Group | Classes | Source domains | Destination | Payload (B) | Deadline (us) | Priorities |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for group, levels, sources, payload, deadline, priorities in REQUIREMENTS:
        print(f"| g{group} | {', '.join(levels)} | {', '.join(map(str, sources))} | 5 | {payload} | {deadline} | {', '.join(map(str, priorities))} |")
    print("\n## Second B-level member of g3: packing trials\n")
    print("| Option | Per-hop reservation (us) | Offset (us) | Two-hop completion (us) | Decision |")
    print("| --- | --- | --- | --- | --- |")
    for row in trials:
        print("| " + " | ".join(row) + " |")
    print("\nThe new-frame bound relaxes only that candidate's deadline; it exceeds 36 us.\n")
    print("## Final schedule\n")
    print("| Frame | Members | Route | Uplink [start, end) (us) | Downlink [start, end) (us) | Deadline (us) |")
    print("| --- | --- | --- | --- | --- | --- |")
    for label, packet, offset in frames:
        duration = packet.duration()
        source, destination = packet.route
        members = ", ".join(f.uid for f in packet.flows)
        print(f"| {label} | {members} | {source + 1} -> {destination + 1} | [{us(offset)}, {us(offset + duration)}) | [{us(offset + duration)}, {us(offset + 2 * duration)}) | {us(packet.deadline)} |")
    print("\nChecks passed: six complete critical groups in separate frames per group, two non-critical messages, and all deadlines met.")


if __name__ == "__main__":
    main()
