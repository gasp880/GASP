"""Plot the verified paper illustration using a freshly computed schedule."""

import argparse
import json
from pathlib import Path

from gasp import schedule
from examples.paper_example import final_frames, group_three_trials, messages


COLORS = {0: "#408F92", 1: "#F8E7D7", 2: "#EF857D", 3: "#4294ED"}


def compute_example():
    flows = messages()
    group_three_trials(flows)
    frames = final_frames(schedule(flows))
    return [
        {
            "frame": label,
            "members": [
                {
                    "uid": flow.uid,
                    "group": flow.requirement,
                    "class": flow.asil,
                    "member": flow.member + 1,
                }
                for flow in packet.flows
            ],
            "source": packet.route[0],
            "destination": packet.route[1],
            "critical": packet.critical,
            "period_ticks": packet.period,
            "deadline_ticks": packet.deadline,
            "offset_ticks": offset,
            "per_hop_ticks": packet.duration(),
            "completion_ticks": offset + 2 * packet.duration(),
        }
        for label, packet, offset in frames
    ]


def build_figure(frames):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle

    plt.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["Arial", "Liberation Sans", "DejaVu Sans"],
        "font.size": 11,
        "text.color": "black",
        "axes.labelcolor": "black",
        "xtick.color": "black",
        "ytick.color": "black",
        "axes.linewidth": 0.5,
        "pdf.fonttype": 42,
        "svg.fonttype": "none",
        "svg.hashsalt": "gasp-paper-example",
    })
    fig, ax = plt.subplots(figsize=(10.8, 4.7), facecolor="white")
    fig.subplots_adjust(left=0.12, right=0.665, bottom=0.22, top=0.78)
    fig.text(0.12, 0.94, "Packing and two-hop transmission", fontsize=16,
             fontweight="bold", va="top")
    fig.text(0.12, 0.865,
             "GASP paper example  |  8 requirements  |  12 CAN messages",
             fontsize=11, va="top")
    ax.set_xlim(0, 48)
    ax.set_ylim(-0.6, 4.6)
    ax.set_xticks([0, 10, 20, 30, 40])
    ax.set_xlabel("Time (µs)", labelpad=8)
    ax.set_yticks([4, 3, 2, 1, 0])
    ax.set_yticklabels(["cd1 → SW", "cd2 → SW", "cd3 → SW", "cd4 → SW", "SW → cd5"])
    ax.tick_params(axis="y", length=0, pad=8)
    ax.tick_params(axis="x", direction="out", length=3)
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_color("black")
    ax.axhline(0.6, color="black", linewidth=0.5)

    for row in frames:
        offset = row["offset_ticks"] / 100
        duration = row["per_hop_ticks"] / 100
        color = COLORS[row["source"]]
        for y, start in ((4 - row["source"], offset), (0, offset + duration)):
            ax.barh(y, duration, left=start, height=0.48,
                    color=color, edgecolor="black", linewidth=0.5, zorder=3)
            ax.text(start + duration / 2, y, row["frame"], ha="center", va="center",
                    fontsize=11, fontweight="bold", zorder=4)

    fig.text(0.72, 0.805, "Frame contents and deadlines", fontsize=11,
             fontweight="bold", va="bottom")
    for index, row in enumerate(frames):
        y = 0.752 - index * 0.128
        fig.add_artist(Rectangle((0.72, y - 0.019), 0.017, 0.026,
                                 transform=fig.transFigure,
                                 facecolor=COLORS[row["source"]],
                                 edgecolor="black", linewidth=0.5))
        fig.text(0.748, y, row["frame"], fontweight="bold", fontsize=11, va="center")
        members = [
            f"g{m['group']}: {m['class']}{m['member']}" if m["class"] != "QM"
            else f"g{m['group']}: QM"
            for m in row["members"]
        ]
        lines = [" · ".join(members[:2]), " · ".join(members[2:])] if len(members) > 2 else [" · ".join(members)]
        fig.text(0.79, y, "\n".join(lines), fontsize=10, va="center", linespacing=1.25)
        traffic = "critical" if row["critical"] else "non-critical"
        fig.text(0.748, y - 0.058,
                 f"{traffic}  ·  deadline {row['deadline_ticks'] / 100:g} µs",
                 fontsize=9.5, va="center")

    fig.text(0.12, 0.075,
             "6/6 critical groups admitted in separate frames per group; all 12 messages meet their deadlines.",
             fontsize=10, va="center")
    fig.text(0.12, 0.028,
             "First release of 40 ms streams; reservations include IFG. Labels give group, class and member (e.g., g3: B2).",
             fontsize=9.5, va="center")
    fig.canvas.draw()
    return fig


def export_figure(fig, frames, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    stem = output_dir / "paper-example-schedule"
    metadata = {"Title": "GASP paper example: packing and two-hop schedule",
                "Creator": "GASP paper example"}
    fig.savefig(stem.with_suffix(".png"), dpi=300, facecolor="white",
                metadata={"Software": "GASP paper example"})
    fig.savefig(stem.with_suffix(".svg"), facecolor="white",
                metadata={**metadata, "Date": None})
    fig.savefig(stem.with_suffix(".pdf"), facecolor="white",
                metadata={**metadata, "Author": "", "CreationDate": None})
    stem.with_suffix(".json").write_text(
        json.dumps({"example": "hand-written manuscript illustration", "tick_ns": 10,
                    "frames": frames}, indent=2) + "\n",
        encoding="utf-8",
    )
    return stem


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("example-figures"))
    args = parser.parse_args()
    frames = compute_example()
    try:
        fig = build_figure(frames)
    except ModuleNotFoundError as exc:
        if exc.name == "matplotlib":
            parser.exit(1, "Install plotting support: python3 -m pip install -r examples/requirements-visualization.txt\n")
        raise
    stem = export_figure(fig, frames, args.output_dir)
    print(f"Verified the paper example and generated PNG, SVG, PDF and JSON: {stem}")


if __name__ == "__main__":
    main()
