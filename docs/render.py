#!/usr/bin/env python3
"""Render statusline.sh output to SVG for the README.

The status line reads a JSON payload on stdin, so any state can be reproduced
without waiting for a real session. This runs the script against a set of
payloads, parses the ANSI escapes it emits, and writes one SVG per state.

    python3 docs/render.py

SVG rather than PNG: it stays crisp at any zoom, weighs a few kilobytes, and
carries no screen capture metadata. Regenerate after changing colours or
wording so the README cannot drift from the script.
"""

import html
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "statusline.sh"
OUT_DIR = ROOT / "docs"
NOW = int(time.time())

# --- Appearance -------------------------------------------------------------

BG = "#282c34"
FG = "#abb2bf"
FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'DejaVu Sans Mono', monospace"
FONT_SIZE = 14
ADVANCE = FONT_SIZE * 0.6  # monospace cell width
LINE_HEIGHT = 22
PAD_X = 16
PAD_Y = 14

# Terminal palette. Keys are the SGR parameters statusline.sh emits.
COLOURS = {
    "31": "#e06c75",      # red
    "32": "#98c379",      # green
    "33": "#e5c07b",      # yellow
    "34": "#61afef",      # blue
    "35": "#c678dd",      # magenta
    "36": "#56b6c2",      # cyan
    "38;5;208": "#ff8700",  # orange (xterm 208)
}

BAR_CHARS = {"█", "░"}  # full block, light shade
DIM_FACTOR = 0.45  # how far a dimmed colour is pulled towards the background


def mix(colour: str, background: str, factor: float) -> str:
    """Blend towards the background, the way a terminal renders faint text."""
    c = [int(colour[i : i + 2], 16) for i in (1, 3, 5)]
    b = [int(background[i : i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(bi + (ci - bi) * factor):02x}" for ci, bi in zip(c, b))


# --- ANSI parsing -----------------------------------------------------------

SGR = re.compile(r"\x1b\[([0-9;]*)m")


def parse(line: str):
    """Split a line into (text, colour, bold, dim) runs of equal styling."""
    runs, pos, colour, bold, dim = [], 0, None, False, False
    for match in SGR.finditer(line):
        if match.start() > pos:
            runs.append((line[pos : match.start()], colour, bold, dim))
        params = match.group(1)
        if params in ("", "0"):
            colour, bold, dim = None, False, False
        elif params == "1":
            bold = True
        elif params == "2":
            dim = True
        elif params in COLOURS:
            colour = params
        pos = match.end()
    if pos < len(line):
        runs.append((line[pos:], colour, bold, dim))
    return [r for r in runs if r[0]]


def fill(colour, dim: bool) -> str:
    base = COLOURS[colour] if colour else FG
    return mix(base, BG, DIM_FACTOR) if dim else base


# --- SVG emission -----------------------------------------------------------

def bar_rects(text: str, colour, dim: bool, x: float, baseline: float) -> str:
    """Draw a block-character run as rectangles.

    Character rendering of U+2588/U+2591 depends on the font that happens to be
    installed, which would shift the rest of the line. Rectangles are identical
    everywhere. The shade character reads as the same hue at low coverage, so it
    becomes the same colour at reduced opacity.
    """
    out, top, height = [], baseline - 11.5, 15.0
    for run_char, count in group(text):
        width = count * ADVANCE
        opacity = 1.0 if run_char == "█" else 0.28
        out.append(
            f'<rect x="{x:.1f}" y="{top:.1f}" width="{width:.1f}" height="{height}" '
            f'fill="{fill(colour, dim)}" opacity="{opacity}"/>'
        )
        x += width
    return "".join(out)


def group(text: str):
    """Run-length encode a string: 'aabbb' -> [('a', 2), ('b', 3)]."""
    out = []
    for char in text:
        if out and out[-1][0] == char:
            out[-1][1] += 1
        else:
            out.append([char, 1])
    return [(char, count) for char, count in out]


def columns(lines: list[str]) -> int:
    """Width of the widest line in character cells, ignoring escape sequences."""
    return max(len(SGR.sub("", line)) for line in lines)


def render(lines: list[str], cols: int) -> str:
    """Render to SVG. `cols` is shared across the set so the cards line up."""
    width = cols * ADVANCE + PAD_X * 2
    height = len(lines) * LINE_HEIGHT + PAD_Y * 2 - (LINE_HEIGHT - FONT_SIZE) + 4

    body = [
        f'<rect width="{width:.0f}" height="{height:.0f}" rx="6" fill="{BG}"/>'
    ]
    for row, line in enumerate(lines):
        baseline = PAD_Y + FONT_SIZE + row * LINE_HEIGHT
        column, spans = 0, []
        for text, colour, bold, dim in parse(line):
            x = PAD_X + column * ADVANCE
            if set(text) <= BAR_CHARS:
                body.append(bar_rects(text, colour, dim, x, baseline))
            else:
                weight = ' font-weight="600"' if bold else ""
                # textLength pins each run to the width its columns are worth.
                # Without it the run is laid out with whichever monospace font
                # the viewer happens to have, and any difference from ADVANCE
                # makes runs overlap — a swallowed space between segments.
                spans.append(
                    f'<tspan x="{x:.1f}" fill="{fill(colour, dim)}"{weight} '
                    f'textLength="{len(text) * ADVANCE:.1f}" lengthAdjust="spacing">'
                    f"{html.escape(text)}</tspan>"
                )
            column += len(text)
        if spans:
            body.append(
                f'<text y="{baseline}" font-family="{FONT}" font-size="{FONT_SIZE}" '
                f'xml:space="preserve">{"".join(spans)}</text>'
            )

    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" '
        f'height="{height:.0f}" viewBox="0 0 {width:.0f} {height:.0f}" '
        f'role="img" aria-label="claude-code-statusline">\n  '
        + "\n  ".join(body)
        + "\n</svg>\n"
    )


# --- States to render -------------------------------------------------------

def payload(*, model, directory, tokens_in, tokens_out, cost, week, five_hour,
            week_hours, window=1_000_000, usage=None, churn=None):
    data = {
        "model": {"display_name": model},
        "effort": {"level": "high"},
        "workspace": {"current_dir": directory},
        "context_window": {
            "total_input_tokens": tokens_in,
            "total_output_tokens": tokens_out,
            "context_window_size": window,
        },
        "cost": {"total_cost_usd": cost},
        "rate_limits": {},
    }
    if week is not None:
        data["rate_limits"]["seven_day"] = {
            "used_percentage": week,
            # One base timestamp for the whole run, plus slack: the script
            # divides the remaining seconds by 3600, so a reset landing exactly
            # on the hour would round down to h-1 in whichever render happens
            # to start a second later.
            "resets_at": NOW + week_hours * 3600 + 300,
        }
    if five_hour is not None:
        data["rate_limits"]["five_hour"] = {"used_percentage": five_hour}
    if usage:
        read, write, fresh = usage
        data["context_window"]["current_usage"] = {
            "cache_read_input_tokens": read,
            "cache_creation_input_tokens": write,
            "input_tokens": fresh,
        }
    if churn:
        data["cost"]["total_lines_added"], data["cost"]["total_lines_removed"] = churn
    return json.dumps(data)


STATES = {
    # Default configuration: nothing to act on.
    "statusline-optimal": dict(
        config={},
        args=dict(model="Claude Sonnet 5", directory="/home/dev/api-gateway",
                  tokens_in=60_376, tokens_out=624, cost=0.42,
                  week=12.0, five_hour=8.0, week_hours=120),
    ),
    # Past the second threshold: orange, and the breakdown line switched on.
    "statusline-expensive": dict(
        config={"SHOW_BREAKDOWN_LINE": 1},
        args=dict(model="Claude Opus 5 (1M context)", directory="/home/dev/monorepo",
                  tokens_in=260_000, tokens_out=2_000, cost=10.91,
                  week=18.0, five_hour=14.0, week_hours=89,
                  usage=(260_000, 1_000, 2), churn=(96, 44)),
    ),
    # Top band: red and bold, and the weekly figure has turned yellow too.
    "statusline-critical": dict(
        config={"SHOW_BREAKDOWN_LINE": 1},
        args=dict(model="Claude Opus 5 (1M context)",
                  directory="/home/dev/claude-code-statusline",
                  tokens_in=505_000, tokens_out=7_000, cost=18.74,
                  week=74.0, five_hour=46.0, week_hours=31,
                  usage=(500_000, 4_000, 1_000), churn=(318, 141)),
    ),
    # The same 185K of context on two different windows. Only the model and its
    # window size differ, so nothing else can explain the different advice. On
    # 1M the thresholds keep their absolute values; on 200K they are capped to
    # 100K/150K/180K, which puts the identical conversation in the top band.
    #
    # The limit line is off here on purpose. The same token count on two
    # different models does not cost the same, so showing one session figure on
    # both would be inventing a number to make the pair look tidy.
    "statusline-window-1m": dict(
        config={"SHOW_LIMIT_LINE": 0},
        args=dict(model="Claude Opus 5 (1M context)", directory="/home/dev/monorepo",
                  tokens_in=182_000, tokens_out=3_000, window=1_000_000,
                  cost=0, week=None, five_hour=None, week_hours=0),
    ),
    "statusline-window-200k": dict(
        config={"SHOW_LIMIT_LINE": 0},
        args=dict(model="Claude Haiku 4.5", directory="/home/dev/monorepo",
                  tokens_in=182_000, tokens_out=3_000, window=200_000,
                  cost=0, week=None, five_hour=None, week_hours=0),
    ),
}


def main() -> None:
    OUT_DIR.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        rendered = {}
        for name, state in STATES.items():
            # The script applies its defaults unconditionally and only reads
            # overrides from the config file, so per-state settings have to go
            # through one. Pointing at a generated config also keeps a personal
            # ~/.claude/statusline.conf out of the rendered output.
            config = Path(tmp) / f"{name}.conf"
            config.write_text(
                "".join(f"{k}={v}\n" for k, v in state["config"].items())
            )
            result = subprocess.run(
                ["bash", str(SCRIPT)],
                input=payload(**state["args"]),
                env={"CLAUDE_STATUSLINE_CONFIG": str(config),
                     "PATH": os.environ["PATH"], "HOME": os.environ["HOME"]},
                capture_output=True, text=True, check=True,
            )
            rendered[name] = result.stdout.split("\n")

    # One width for the whole set. Stacked in a README, cards of differing
    # widths read as ragged, and in the side-by-side comparison a size
    # difference would draw the eye away from the content difference.
    cols = max(columns(lines) for lines in rendered.values())
    for name, lines in rendered.items():
        target = OUT_DIR / f"{name}.svg"
        target.write_text(render(lines, cols))
        print(f"{target.relative_to(ROOT)}  ({target.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
