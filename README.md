# CalPilot

A macOS calendar assistant written in Swift. It reads every calendar you can see, asks a
language model to work out how your week should be arranged, and writes the result into a
calendar of its own — after you approve it, and in a way you can undo.

Three ways to drive it: a double-clickable window, a turn-based `chat` agent in the
terminal, and a one-shot `plan` command.

## Requirements

- macOS 14 or newer (built and tested against the macOS 15 SDK)
- Swift 6 toolchain (Command Line Tools are enough; Xcode is not required)
- An OpenAI-compatible `/chat/completions` endpoint and an API key

## Build and install

```bash
scripts/build-app.sh          # builds CalPilot.app (GUI) + bin/calpilot (CLI)
bin/calpilot doctor           # triggers the calendar permission prompt
bin/calpilot config set-key sk-...   # stored in the login keychain
```

Then either double-click `dist/CalPilot.app` or run `bin/calpilot chat`.

`doctor` will ask for calendar access the first time. Approve it in
**System Settings → Privacy & Security → Calendars**.

### App icon

`assets/CalPilot.icns` is drawn by `scripts/generate-icon.swift` with CoreGraphics rather
than generated as a bitmap, so the geometry is reproducible and each size is designed
instead of downscaled:

```bash
swift scripts/generate-icon.swift   # rewrites assets/CalPilot.icns + assets/preview/
```

The design is a calendar page with binding rings; one time block is amber, the slot the
model picked. Below 64pt the rings, the extra bars, and the spark turn to mush, so 32pt and
16pt get progressively coarser drawings — three bands survive at 16pt, which is all that
can be read at that size. Check `assets/preview/` after regenerating.

### The two faces of the bundle

`CalPilot.app` contains both programs, so they share one permission identity:

```
Contents/MacOS/CalPilot        the SwiftUI window (double-click this)
Contents/MacOS/calpilot-cli    the command line tool bin/calpilot execs
```

The window is a thin shell over the same engine: a conversation list in the title bar, a
transcript with tool calls, a sidebar that switches between the coming week and an analysis
of the past, a proposal card with **写入 / 放弃**, and settings for the model, availability
rules, and the memory block. Every guard rail applies here too — proposals are validated
locally and nothing is written until you press the button.

### The keychain is per binary

The window and `bin/calpilot` are two different executables, and macOS grants keychain
access per binary rather than per bundle. Whichever one did *not* save the key will ask for
permission the first time it reads it — choose **Always Allow** and it asks only once.

Because the request blocks until it is answered, the command line prints a note explaining
the wait before it happens. To bypass the keychain entirely, export `CALPILOT_API_KEY` or
pass `--api-key`.

### Why a bundle instead of a plain binary

macOS attributes calendar permission to an app identity. A bare executable has none, so it
either never sees a prompt or loses its grant when you rebuild. `build-app.sh` therefore
assembles `dist/CalPilot.app` with the required `NSCalendars*UsageDescription` keys and a
stable bundle identifier, and `bin/calpilot` runs the binary inside it.

By default the bundle is left **unsigned**. Ad-hoc signing (`--sign`) gives you a code
signature, but the identifier hashes the binary, so every rebuild looks like a new app to
TCC and you have to re-grant. Unsigned bundles keep matching on their path.

## Safety model

The design assumption is that a language model will occasionally propose something wrong,
so every write is fenced:

1. **One write target.** Reads span all your calendars; writes only ever go to the calendar
   named in `writeCalendar` (default `CalPilot`, created on first use). Your real calendars
   are never modified.
2. **Propose, then apply.** `plan` prints a plan and exits unless you pass `--apply`. The
   agent's `propose_plan` tool only displays; `apply_plan` is a separate call the user
   confirms.
3. **Local re-validation.** Whatever the model returns is re-checked against the live
   calendar before anyone sees it: conflicts are moved to a legal slot, out-of-hours times
   are pulled into working hours, over-long events are truncated, and daily caps are
   enforced. A hallucinated time cannot be written as-is.
4. **A journal.** Every created event is appended to `~/.config/calpilot/journal.jsonl`, so
   `calpilot undo` can take a batch back. Undo only ever removes events CalPilot recorded.

## First run

```bash
calpilot doctor                                  # access, config, endpoint
calpilot calendars                               # what it can see
calpilot events list --days 7
calpilot free --days 7 --min 60                  # free slots only
```

## Planning

```bash
calpilot plan --goal "这周把论文初稿写完，每天留出健身时间" --days 7
calpilot plan --goal "准备答辩" --task "写讲稿:180" --task "彩排:60" --days 10 --apply
calpilot plan --task "写周报:90" --offline        # no model involved, earliest-fit
calpilot plan --goal "..." --out plan.json        # save a plan
calpilot apply plan.json                          # write it later
calpilot undo                                     # take the last batch back
```

Every `plan` run is a dry run until `--apply`. `--offline` schedules without a language
model, which is also how the engine is exercised without an API key.

## Reviewing past time

```bash
calpilot analyze --days 30
calpilot analyze --from 2026-09-01 --to 2026-10-01
calpilot analyze --days 90 --json
```

Computed locally, so it costs no tokens and needs no API key. It reports hours per
calendar, average and total load per weekday, the busiest days, how much of your available
time is booked, how fragmented the free time is, and a few plain-language observations.

The agent has the same numbers behind the `calendar_analysis` tool, so asking "我上个月时间
都花哪了" in `chat` quotes real arithmetic rather than guessing.

## The agent

```bash
calpilot chat
```

One line in, one turn out. The agent inspects your real calendar with tools, proposes
plans, remembers durable preferences, and writes only after you confirm.

```
› 帮我把这周的论文进度排一下
  · find_free_slots(now → +7d)
    → 9 free slot(s), 22h 30m total
  · propose_plan(5 events)
    → 5 event(s) proposed
  ...
› 周三下午不要排，我有组会
  · propose_plan(5 events)
  ...
› 就这样
  · apply_plan()
Write 5 event(s) into "CalPilot"? [Y/n]
```

Commands inside the session: `/events`, `/free`, `/plan <goal>`, `/apply`, `/undo`,
`/memories`, `/memory <text>`, `/pin <text>`, `/forget <id>`, `/usage`, `/reset`, `/exit`.

### Tools the agent can call

| Tool | Effect |
| --- | --- |
| `list_events` | read existing events in a window |
| `find_free_slots` | read free slots, buffers already applied |
| `propose_plan` | validate and display a plan (no write) |
| `apply_plan` | write the pending plan, after confirmation |
| `undo_last_batch` | remove the last batch CalPilot wrote |
| `list_memories`, `remember`, `forget` | maintain the personal memory block |
| `answer` | reply without touching the calendar |

Endpoints without native tool calling are detected and switched to a JSON protocol
(`{"tool": ..., "arguments": ...}`) automatically.

## Conversation persistence

Conversations are saved after every turn to `~/.config/calpilot/sessions/`, one JSON file
each so a single corrupt file cannot take the history with it.

```bash
calpilot sessions list
calpilot sessions show 3f9ac2b1
calpilot sessions remove 3f9ac2b1
calpilot chat --resume 3f9ac2b1
```

Each file stores two views of the same exchange: the visible turns, and the model's real
transcript including tool calls and their results. Resuming restores the second one, so the
agent keeps its context instead of starting over. The system prompt itself is *not*
restored verbatim — it is rebuilt from the current config and memory on the next turn, so a
preference you added since the session was saved still applies.

The window lists your conversations in the title-bar menu; the same files back both
interfaces, so a conversation started in the terminal can be continued in the window.

## Personal memory block

Durable statements about how you like your time arranged. They are injected into both the
one-shot planner and the agent, ahead of the built-in defaults.

```bash
calpilot memory add "上午做深度工作，不要安排会议" --kind preference
calpilot memory add "周三晚上不排事情" --kind constraint --pin
calpilot memory add "和张老师开会要留 30 分钟缓冲" --kind person
calpilot memory list
calpilot memory remove 3f9a
```

The agent also writes here on its own: when you say "我下午效率低", it calls `remember`.
Stored in `~/.config/calpilot/memory.json`; pinned entries are always in the prompt.

## User-turn timestamps

Every user message handed to the model is prefixed with the wall clock:

```
[time: 2026-09-27 20:45:12 +08:00 | timezone: Asia/Shanghai | weekday: Sun | 12m since your previous message]
帮我安排这周
```

This is what lets the model resolve "今天", "下周三", and detect that a conversation has
gone stale between turns.

## Prompt caching

Cloud prompt caches hash the **exact request bytes**, so a request that differs by one
character is a full-price cache miss. Two consequences shape the implementation:

1. **Byte-stable payloads across process launches.** `JSONEncoder` walks its keyed
   containers in per-process hash order, so without `.sortedKeys` the same payload
   serializes differently after every restart and the cache never hits again. Every request
   encoder sets `.sortedKeys`, optional fields are omitted rather than emitted as `null`,
   and tool schemas (plain dictionaries) are sorted the same way.
2. **An append-only transcript with a stable prefix.** The system prompt contains no clock
   data and is rebuilt only when the memory block or the agent mode actually changes.
   Everything volatile rides at the front of the newest user message. Trimming the
   transcript is the one operation that cannot preserve the prefix, so it only happens far
   past a normal session length.

`/usage` in a chat session reports the split, which is the only honest way to know the
cache is working:

```bash
calpilot chat --goal "安排这周" --once
```

## Availability rules

CalPilot only schedules into hours you declare. The original shape was a work week — one
weekday window plus a lunch break — which does not fit school, shift work, or any week whose
days differ. So the window is now a list of rules, grouped by weekday:

```bash
calpilot schedule show
calpilot schedule preset school          # a starting point you then edit
calpilot schedule add --days mon,tue,wed,thu,fri --start 07:40 --end 21:00 \
    --break 11:40-12:30 --break 17:00-18:00
calpilot schedule add --days sat,sun --start 10:00 --end 18:00
calpilot schedule remove 1
calpilot schedule clear                  # back to the single legacy window
```

Rules are unioned when they overlap, and each rule's breaks are subtracted. Weekdays are
given by name (`mon`, `周一`, `每天`) rather than by number, because "1" means Monday to most
people and Sunday to `Calendar`. The window's Settings panel edits the same rules.

Breaks tolerate annotations: `11:40-12:30（学校）` parses. It did not before, and a note in
that field silently deleted the break — so unreadable values are now reported instead of
ignored (`calpilot doctor`, `plan`, and the window all say so).

The legacy `workDayStart` / `workDayEnd` / `workDays` / `lunchBreak` fields still work and
are used when no rules exist.

## Configuration

`~/.config/calpilot/config.json`

```json
{
  "baseURL": "https://api.openai.com/v1",
  "model": "gpt-4o-mini",
  "apiKeyEnv": "OPENAI_API_KEY",
  "chatPath": "/chat/completions",
  "writeCalendar": "CalPilot",
  "autoCreateCalendar": true,
  "timeZone": "Asia/Shanghai",
  "schedule": [
    { "days": [2, 3, 4, 5, 6], "start": "07:40", "end": "21:00", "breaks": ["11:40-12:30"] },
    { "days": [1, 7], "start": "10:00", "end": "18:00", "breaks": [] }
  ],
  "defaultEventMinutes": 60,
  "bufferMinutes": 10,
  "maxEventsPerDay": 4,
  "extraInstructions": ""
}
```

`config set` edits one field at a time:

```bash
calpilot config set --model deepseek-chat --base-url https://api.deepseek.com/v1
calpilot config set --buffer-minutes 15 --max-events-per-day 3
```

Weekday numbers in `days` follow `Calendar`: 1 = Sunday … 7 = Saturday.

The API key resolves in this order: `--api-key`, `CALPILOT_API_KEY`, the environment
variable named by `apiKeyEnv`, then the keychain entry for the endpoint's host.

## Checks

```bash
calpilot selftest     # 100 checks
```

Date parsing, availability rules, free slots, plan validation, past-time analysis, session
round-trips (including the disk path), the personal memory block, prompt-cache byte
stability, recovery of a resumed conversation, and an offline turn loop driven by a
scripted client.

## Layout

```
Sources/CalPilotCore/     engine (no UI)
  CalendarService.swift     EventKit read/write, one write target
  SlotFinder.swift          working windows, free slots, buffer handling, snapping
  Planner.swift             prompt construction and plan validation
  Agent.swift               turn-based loop, stable prompts, usage accounting
  ToolCatalog.swift         agent tools and their schemas
  Memory.swift              personal memory block
  Sessions.swift            saved conversations (visible turns + model transcript)
  CalendarAnalysis.swift    deterministic past-time statistics
  PlanApplier.swift         the only writer; journals everything
  LLMClient.swift           OpenAI-compatible client, tools, cache-aware encoding
Sources/calpilot/         CLI
Sources/CalPilotApp/      SwiftUI window (AppModel + ContentView + SettingsView)
assets/CalPilot.icns      generated app icon + preview renders
scripts/generate-icon.swift  icon generator (CoreGraphics)
scripts/build-app.sh      bundle assembly
```

## Known limits

- Repeating events are read as-is; CalPilot only creates single events.
- Analysis counts time inside your declared availability only, so a class outside those
  hours still shows up in the event list but not in the utilisation figure.
- EventKit cannot force a sync, so a freshly written event may take a moment to reach
  other devices.
- Calendar permission for a rebuilt unsigned bundle depends on the path staying the same;
  moving `CalPilot.app` will prompt again.
