# clockodo.sh

A single-file Bash + curl CLI for recording completed work entries in
[Clockodo](https://www.clockodo.com) via its REST API (`/api/v2/entries`).

Requires `bash`, `curl` and `jq`. Works on macOS (BSD `date`) and Linux (GNU `date`).

## Setup

```bash
chmod +x clockodo.sh
mv clockodo.sh /usr/local/bin/clockodo      # optional
clockodo.sh log 09:00-17:00 "Anything"      # first run writes the config
```

On its first run — any command, not just `init` — the script notices there is
no config, writes a fully commented example to `~/.config/clockodo/config`
(mode 600) and exits 1 telling you to fill it in. `clockodo.sh init` does the
same thing explicitly. Every setting in it is commented out and shows its
built-in default, so uncomment only what you want to change; the two
credentials are the minimum:

- `CLOCKODO_EMAIL` — your Clockodo login email
- `CLOCKODO_API_KEY` — Clockodo → your name (top right) → **Personal data** → **API key**

Then look up the numeric IDs you work with and put the ones you use most into
the config as defaults:

```bash
clockodo.sh ids                        # customers, projects and services
clockodo.sh ids projects               # just projects, with their customer
clockodo.sh ids services
clockodo.sh ids projects --customer 12345   # one customer's projects
clockodo.sh ids projects relaunch           # substring search
clockodo.sh ids users
clockodo.sh check          # verifies credentials and prints resolved settings
```

The config is a plain shell file sourced by the script.
`CLOCKODO_EMAIL`, `CLOCKODO_API_KEY`, `CLOCKODO_APP_NAME` and `CLOCKODO_TZ`
can also be set as environment variables, which take precedence — useful if
you keep the key in a password manager or `pass`:

```bash
CLOCKODO_API_KEY="$(pass clockodo/api)" clockodo.sh log 09:00-17:00 "Work"
```

## Recording hours

```bash
# start–end shorthand, everything else from the config defaults
clockodo.sh log 09:00-17:00 "Refactored the import job"

# explicit flags
clockodo.sh log --since 13:00 --until 17:45 --text "Client meeting"

# duration instead of an end time
clockodo.sh log --since 09:00 --duration 2h30m

# a different day: yesterday, a date, or -N days ago
clockodo.sh log --date yesterday 13:00-17:00 "Bug fixing"
clockodo.sh log --date 2026-08-14 -s 09:00 -u 12:00 "Sprint planning"
clockodo.sh log --date -3 08:30-12:00 "Docs"

# override customer / project / service / billability for one entry
clockodo.sh log 10:00-11:00 -p 22222 -S 33333 -b 0 "Internal admin"

# check what would be sent, without sending it
clockodo.sh log 09:00-17:00 "Work" --dry-run
```

Times are written in your local time zone (`CLOCKODO_TZ`, default
`Europe/Vienna`) and converted to UTC for the API. An end time earlier than
the start is treated as past midnight, so `22:00-01:30` records 3.5 h.
`0915` is accepted as shorthand for `09:15`.

### Randomised start times

So that an automated daily entry doesn't read as "09:00:00 sharp, every day".
Give a range and the start is picked at random inside it, always landing on a
step boundary — 15 minutes by default, so only `:00`, `:15`, `:30` or `:45`:

```bash
clockodo.sh log --random-start 07:30-09:00 --duration 8h "Regular work"
```

```
Mon 2026-08-17  08:15–16:15  8.00 h (8h 00m)
  picked at random from 07:30–09:00 in 15-minute steps (7 options)
```

Set a default range in the config and plain `log` randomises on its own,
which is what makes the cron line below worth having:

```bash
CLOCKODO_RANDOM_START="07:30-09:00"
CLOCKODO_RANDOM_STEP="15"      # 30 for half-hour boundaries, 60 for whole hours
```

```bash
clockodo.sh log --duration 8h "Regular work"   # start randomised from the config
clockodo.sh log -r 08:00-10:00 -D 6h           # override the range for one run
clockodo.sh log -r -D 8h --random-step 30      # config range, half-hour steps
```

Details:

- It needs `--duration`, not `--until` — the end moves with the start, so a
  fixed end time would silently change the length of your day. Combining the
  two is refused rather than guessed at.
- An explicit `--since` always wins; `-r` alongside it warns and is ignored.
- The range is rounded **inward** onto the step grid, so `07:35-09:05` with a
  15-minute step yields `07:45 … 09:00`. A range containing no boundary at
  all is an error rather than a silent fallback.
- Randomness comes from `/dev/urandom` (with `$RANDOM` as fallback) and uses
  rejection sampling, so 7 quarter-hour slots are genuinely equally likely
  rather than the first few being slightly favoured. `--seed N` makes the
  choice reproducible if you want to test.

### Breaks

Above a threshold, the day is booked as **two entries** with an unrecorded
gap, rather than one implausible unbroken block:

```bash
clockodo.sh log --random-start 07:30-09:00 --duration 7h30m "Regular work"
```

```
Mon 2026-08-17  07:45–15:45  7.50 h (7h 30m)
  picked at random from 07:30–09:00 in 15-minute steps (7 options)
  two entries, 30 min break at 12:00
✓ 07:45–12:00 recorded (entry 4471203)
✓ 12:30–15:45 recorded (entry 4471204)
```

```bash
CLOCKODO_BREAK_DURATION="30m"   # empty or 0 disables breaks
CLOCKODO_BREAK_AT="12:00"       # empty = always halfway through
CLOCKODO_BREAK_AFTER="6h"       # only break when work exceeds this
```

Per run: `--break 45m`, `--break-at 13:00`, `--no-break`.

Two things worth knowing about the arithmetic:

- **With `--duration` the break extends the day.** `--duration 7h30m` means
  7h30m of *recorded work*, so the day ends 30 minutes later than the start
  plus the duration. **With `--until` the break is carved out of the span:**
  `09:00-17:00` books 7h30m across two entries. Each reading is the natural
  one for that flag, but they are opposites, so it's worth being deliberate
  about which you use.
- **If the configured break time doesn't fit, it falls back to halfway.**
  A late start, a short day, or a randomised start that lands past the break
  time would otherwise produce a zero-length or negative first segment. The
  fallback lands on the step grid and says so in the output. Each segment is
  required to be at least 15 minutes.

If the second entry fails after the first succeeded, the first is deleted
again — a half-booked day looks like a real one, which is worse than nothing.

### Aliases

For combinations you use often, define aliases in the config:

```bash
ALIAS_acme_CUSTOMERS_ID=11111
ALIAS_acme_PROJECTS_ID=22222
ALIAS_acme_SERVICES_ID=33333

ALIAS_admin_SERVICES_ID=44444
ALIAS_admin_BILLABLE=0
ALIAS_admin_TEXT="Internal admin"
```

```bash
clockodo.sh log --alias acme 09:00-17:00 "Sprint work"
clockodo.sh log --alias admin --since 17:00 --duration 30m
```

Only the fields an alias sets are overridden; the rest fall back to the
config defaults, and explicit flags beat both.

## Guards

Before writing anything, `log` decides whether the day is worth booking at
all. If a guard trips it prints one line explaining why and exits **0**
without creating an entry, so a cron job or login hook stays quiet instead
of quietly double-booking you.

| Guard | Trips when | Config |
|---|---|---|
| working day | the weekday is not in your working week | `CLOCKODO_SKIP_NON_WORKDAYS`, `CLOCKODO_WORKDAYS` |
| holiday | the date is in your Clockodo nonbusiness calendar | `CLOCKODO_SKIP_HOLIDAYS`, `CLOCKODO_NONBUSINESSGROUPS_ID` |
| absence | you have holiday / sick leave / … booked | `CLOCKODO_SKIP_ABSENCES`, `CLOCKODO_ABSENCE_STATUSES`, `CLOCKODO_ABSENCE_IGNORE_TYPES` |
| existing entries | the day already has entries of yours | `CLOCKODO_ON_EXISTING_ENTRIES` |

```bash
clockodo.sh guard                     # what would happen today, check by check
clockodo.sh guard --date 2026-12-24
clockodo.sh guard --types             # absence type numbers
```

```
2026-08-17 (Monday)

  ✓ working day       clear
  ✓ holiday           clear
  ✓ absence           clear
  ✗ existing entries  1 entry already booked on 2026-08-17 (4.50 h)

— a `log` for 2026-08-17 would be skipped (use --force to override)
```

Details worth knowing:

- **Working days** — `CLOCKODO_WORKDAYS` uses ISO weekday numbers with
  Monday = 1, so `"1-5"` is Mon–Fri and `"1,2,4"` is Mon/Tue/Thu.
- **Half holidays** are logged with a warning rather than skipped — you do
  work on the morning of Christmas Eve.
- **Absences** are matched against your own user only. By default both
  *requested* and *approved* absences block (`CLOCKODO_ABSENCE_STATUSES="0,1"`);
  home office (8) and work-out-of-office (9) don't, since you're working
  then. Declined and cancelled absences never block.
- **Existing entries** has three modes: `any` (default — the day already has
  something of yours, so leave it alone), `overlap` (only refuse when the new
  time range actually collides, which is what you want if you log several
  blocks a day), and `off`. Override for one run with `--on-existing overlap`.
- **`--force`** bypasses every guard; **`-q`** silences the skip message.
- The skip exit code is configurable via `CLOCKODO_SKIP_EXIT_CODE` if you
  want a wrapper to distinguish "skipped" from "recorded".

Holiday calendars, absences and your user ID are cached under
`~/.cache/clockodo` (30 days / 6 hours / 7 days), so a guarded `log` normally
costs one extra API call rather than four. `--refresh` ignores the cache for
one run and `clockodo.sh cache-clear` empties it.

### Running it unattended

The intended deployment: a daily cron job on an always-on Linux box.

```cron
MAILTO=you@example.com
PATH=/usr/local/bin:/usr/bin:/bin

# 18:30 Mon–Fri: book a standard day unless a guard says otherwise
30 18 * * 1-5  /usr/local/bin/clockodo.sh log --duration 7h30m "Regular work" --quiet
```

`--quiet` is what makes the mail useful: on success and on an expected skip
the script prints **nothing at all**, so cron sends no mail. Warnings and
errors still go to stderr, so mail arrives only when something actually needs
you — the API is down, credentials stopped working, an entry was rejected.
Set `CLOCKODO_LOG=/var/log/clockodo.log` (or pass `--log`) to keep a one-line
record of every run regardless:

```
2026-08-17 18:30:02+0200  LOG    2026-08-17  07:45-15:45  7.50 h (7h 30m) +30min break  entries: 4471203 4471204  Regular work
2026-08-18 18:30:01+0200  SKIP   2026-08-18  public holiday: Assumption Day
2026-08-19 18:30:04+0200  ERROR  HTTP 500 on /v2/entries: internal error
```

Notes for unattended runs:

- The weekday guard makes the `1-5` in the cron line redundant, but holidays,
  vacation and days you already tracked by hand are handled too — those are
  the cases cron cannot know about.
- Set `PATH` in the crontab. cron's default `PATH` is `/usr/bin:/bin`, which
  misses `jq` on many installs. The script also appends `/usr/local/bin` and
  `/opt/homebrew/bin` itself, and falls back to looking `HOME` up from the
  passwd database if cron doesn't set it.
- A lock (`$TMPDIR/clockodo-$UID.lock`) stops a scheduled run and a manual one
  from booking the same day twice. A lock older than 5 minutes is treated as a
  crashed run and reclaimed.
- Re-running is safe: the existing-entries guard means a second run on the
  same day does nothing.

## Reviewing and correcting

```bash
clockodo.sh list                       # today
clockodo.sh list --date yesterday
clockodo.sh list --week                # Mon–Sun of the current week
clockodo.sh list --month
clockodo.sh list --from 2026-08-01 --to 2026-08-15
clockodo.sh list --week --json | jq .  # raw API output

clockodo.sh delete 12345678            # entry IDs are shown by `list`
```

## Command summary

| Command | What it does |
|---|---|
| `log` | record a completed entry (guarded) |
| `guard` | show what each guard thinks about a day |
| `list` | entries and totals for a day, week, month or range |
| `ids [kind] [search]` | customer / project / service / user IDs |
| `delete ID` | remove an entry |
| `check` | verify credentials, print resolved config and guards |
| `init` | write the example config |
| `cache-clear` | drop cached holiday/absence/user lookups |

Global flags: `--config FILE`, `--log FILE`, `--refresh`, `-v`, `--version`.

## Notes

- `-v` prints each HTTP request and response, which is the fastest way to
  debug a rejected entry.
- Clockodo versions resources individually (`/v2/entries` but `/v4/absences`)
  and bumps them over time. The script tries the known paths newest-first and
  uses whichever one your account answers, so a version bump degrades to one
  wasted 404 rather than a broken script.
- Transient failures (HTTP 429 and 5xx) are retried up to three times with
  backoff; 401/403 fails immediately with a pointer at the config.
- The script sends the `X-Clockodo-External-Application` header Clockodo
  asks API clients to identify themselves with. App name and email together
  must stay under 50 characters.
- The running-timer endpoint (`/api/v2/clock`) is not used — this records
  completed blocks only.

Sources: [Clockodo API basics](https://www.clockodo.com/en/api/) ·
[/api/v2/entries](https://www.clockodo.com/en/api/entries/) ·
[nonbusiness days](https://www.clockodo.com/en/api/nonbusinessdays/) ·
[peerigon/clockodo SDK](https://github.com/peerigon/clockodo) (absence type
and status codes)
