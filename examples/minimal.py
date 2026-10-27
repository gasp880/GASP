"""Small hand-written API example, independent of the paper workloads."""

from gasp import Flow, schedule

messages = (
    Flow("g0:A", 0, "D", "A", 0, 0, 4, 1_000_000, 8, 50_000, 1),
    Flow("g0:C", 0, "D", "C", 1, 1, 4, 1_000_000, 8, 50_000, 2),
    Flow("g1:B", 1, "B", "B", 0, 0, 4, 1_000_000, 8, 50_000, 3),
    Flow("n0", 2, "QM", "QM", 0, 2, 4, 1_000_000, 8, 70_000, 4),
)

if __name__ == "__main__":
    for packet, offset in schedule(messages):
        print(tuple(flow.uid for flow in packet.flows), "offset_ticks=", offset)
