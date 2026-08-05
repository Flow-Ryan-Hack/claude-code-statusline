# claude-code-statusline

A [Claude Code](https://claude.com/claude-code) status line built around two questions:

1. **How expensive is this conversation getting?**
2. **How much of my rate limit is left?**

![A five-line status line. Model and reasoning effort on the first line. A context bar
reading 262K of 1.0M, orange, with the hint "expensive, /compact now". The threshold scale
100K / 200K / 400K, with the second threshold highlighted. The context composition: 99%
cached, 260K read, 1K written. Weekly and 5-hour limits, and a session cost of
$10.91.](docs/statusline-expensive.svg)

## Why absolute tokens, not percentages

Most context indicators show "42% used". That number is misleading for cost: 42% of a
1M window is 440K tokens, which is expensive, while 42% of a 200K window is 84K, which
is not. Cost scales with **absolute** tokens — 150K tokens cost the same regardless of
how big the window happens to be.

So the thresholds here are absolute: 100K / 200K / 400K. On a model with a small window
each threshold is additionally capped at a share of that window (50% / 75% / 90%), so a
200K-window model still warns you before the window runs out. Nothing to configure per
model — the window size comes from Claude Code and the scale adapts.

### The same conversation, a different window

Two sessions carrying an identical 185K of context, in the same directory. The only
difference is the model and the size of its window.

![Status line on Claude Opus 5 with a 1M window. The context bar reads 185K of 1.0M in
yellow, with the hint "ok, /compact on topic switch". The threshold scale reads 100K keep
going, 200K /compact on switch, 400K /compact or
/clear.](docs/statusline-window-1m.svg)

![Status line on Claude Haiku 4.5 with a 200K window. The same 185K of context, but the
bar is nearly full and red, with the bold hint "very expensive, /compact, or /clear if
done". The threshold scale has adapted to 100K keep going, 150K /compact on switch, 180K
/compact or /clear.](docs/statusline-window-200k.svg)

Line 3 shows the mechanism: the scale itself has moved from 100K / 200K / 400K down to
100K / 150K / 180K, because 90% of a 200K window is 180K. The same conversation that has
room to grow on the first model is in the top band on the second.

A percentage indicator would have called these two sessions "19% used" and "93% used".
Both are re-sending the same 185K of context on every single turn.

## What each line tells you

| Line | Content |
|---|---|
| 1 | Model, reasoning effort, and where you're working |
| 2 | Context bar, absolute tokens / window size, and what to do about it |
| 3 | The three thresholds, coloured by where you currently stand |
| 4 | What the context is made of — cache hit rate, and code churn (optional) |
| 5 | Weekly limit, 5-hour limit, session cost |

**Line 2 colours:** green under 100K, yellow under 200K, orange under 400K, red above.
The hint is always visible so you never have to remember the bands.

![Status line in the green band. Claude Sonnet 5, a context bar reading 61K of 1.0M, and
the hint "optimal, nothing to do". Four lines: the composition line is off in the default
configuration.](docs/statusline-optimal.svg)

*Green, default configuration — four lines and nothing to act on.*

![Status line in the red band. A full context bar reading 512K of 1.0M with the bold hint
"very expensive, /compact, or /clear if done". All three thresholds are red, and the weekly
limit reads 74% in yellow.](docs/statusline-critical.svg)

*Red and bold, past the top threshold, with the optional composition line switched on. The
weekly figure has turned yellow at 74%.*

**Why the hints say `/compact` before `/clear`:** `/clear` starts an empty session and
throws the conversation away, so you pay for re-explaining everything. `/compact` replaces
the history with a summary and keeps working from there, which is almost always the
cheaper move mid-topic. You can even steer it: `/compact focus on the parser refactor`.
`/clear` earns its place once a topic is genuinely finished, which is why it only shows up
in the top band.

**Line 3 colours:** a threshold you are below is dimmed green (not relevant yet), the
band you are currently in is yellow, and thresholds you've passed are red.

**Line 4** is off by default because five lines is a lot. Turn it on with
`SHOW_BREAKDOWN_LINE=1`. `cached` is the share of input served from the prompt cache —
cache reads cost about a tenth of fresh input, so a falling number is the clearest early
signal that a conversation is getting expensive. Note these figures describe the context
window **as it stands right now**, not cumulative session totals; the status line payload
only reports the current window.

## Install

Requires `bash` 3.2 or newer and [`jq`](https://jqlang.github.io/jq/). That includes the
`/bin/bash` that ships with macOS, so there is nothing to install on a Mac beyond `jq`.

```sh
git clone https://github.com/Flow-Ryan-Hack/claude-code-statusline.git
install -m 755 claude-code-statusline/statusline.sh ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 1
  }
}
```

The status line updates on its own — no restart needed.

## Configure

Everything is optional. Copy the example and edit what you want:

```sh
cp claude-code-statusline/statusline.conf.example ~/.claude/statusline.conf
```

The config file is sourced by bash, so the colour variables (`$RED`, `$BLUE`, `$DIM`,
`$R`, …) are available. Anything you leave out keeps its default. Point at a different
file with `CLAUDE_STATUSLINE_CONFIG`.

Common tweaks:

```bash
SHOW_BREAKDOWN_LINE=1       # show the context composition line
SHOW_LIMIT_LINE=0           # hide rate limits and cost
THRESHOLD_1=50000           # warn earlier
HINT_4="stop. /compact."    # your own wording
```

### Location labels

Line 1 ends with where you're working. By default that's the folder name (and `~` for
your home directory). Override `dir_label` to map your own directories:

```bash
dir_label() {
  case "$1" in
    "$HOME")            printf '%s' "${RED}⚠ no project${R}" ;;
    "$HOME"/work/*)     printf '%s' "${BLUE}work${R}" ;;
    "$HOME"/personal/*) printf '%s' "${GREEN}personal${R}" ;;
    *)                  printf '%s' "${DIM}${1##*/}${R}" ;;
  esac
}
```

This is useful if you keep separate contexts that must not get mixed up — the colour
tells you at a glance which one you're in.

## Testing a change

The script reads a JSON payload on stdin, so you can render any state without waiting
for a real session:

```sh
printf '{"model":{"display_name":"Claude Opus 5"},"effort":{"level":"high"},
  "workspace":{"current_dir":"'"$HOME"'"},
  "context_window":{"total_input_tokens":310000,"total_output_tokens":0,
                    "context_window_size":1000000},
  "cost":{"total_cost_usd":1.37}}' | ./statusline.sh
```

The images in this README are generated the same way, by `docs/render.py`, which runs the
script against a set of payloads and converts the ANSI output to SVG. They are renders of
the real script rather than screenshots, so they cannot drift from the code and carry no
capture metadata. Regenerate after changing colours or wording:

```sh
python3 docs/render.py
```

## Notes

- The script runs on every status line update, so it stays to `jq` plus arithmetic. Avoid
  adding `git status` or anything else that shells out per render — it's noticeable.
- Rate limit and cost fields are absent early in a session; those parts simply don't render.
- A missing or zero context window falls back to 200K rather than dividing by zero.

## Licence

MIT

---

An independent community tool. Not affiliated with, endorsed by, or supported by Anthropic.
"Claude" and "Claude Code" are trademarks of Anthropic.
