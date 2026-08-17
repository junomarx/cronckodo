#!/usr/bin/env bash
#
# clockodo.sh — record work hours in Clockodo from the command line.
#
#   clockodo.sh log --random-start 07:30-09:00 --duration 8h "Work"
#   clockodo.sh log 09:00-17:00 "Text"     record a completed entry
#   clockodo.sh list --week                show entries and totals
#   clockodo.sh ids projects               look up IDs for the config
#
# Docs: https://www.clockodo.com/en/api/entries/
# Requires: bash 3.2+, curl, jq

set -euo pipefail

VERSION="1.4.0"

# cron and launchd start with a near-empty environment: no HOME on some
# setups, and a PATH that misses Homebrew, where jq usually lives.
if [ -z "${HOME:-}" ]; then
  HOME=$(eval echo "~$(id -un)" 2>/dev/null) || HOME=''
  [ -d "${HOME:-}" ] || HOME=/tmp
  export HOME
fi
case ":$PATH:" in
  *:/usr/local/bin:*) : ;;
  *) PATH="$PATH:/usr/local/bin" ;;
esac
case ":$PATH:" in
  *:/opt/homebrew/bin:*) : ;;
  *) PATH="$PATH:/opt/homebrew/bin" ;;
esac
export PATH

API_BASE="${CLOCKODO_API_BASE:-https://my.clockodo.com/api}"
CONFIG_FILE="${CLOCKODO_CONFIG:-$HOME/.config/clockodo/config}"

# ---------------------------------------------------------------- output ----

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

# Most of this script's work happens inside command substitutions, where a
# plain `exit` would only end the subshell and let the caller carry on with
# empty output. Signalling the top-level shell makes an error actually fatal.
TOP_PID=$$
trap 'exit 1' TERM

die() {
  printf '%sError:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  audit "ERROR  $*"
  kill -TERM "$TOP_PID" 2>/dev/null || true
  exit 1
}
warn() { printf '%sWarning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }

# One line per outcome, for unattended runs where nobody reads stdout.
LOG_FILE="${CLOCKODO_LOG:-}"
audit() {
  [ -n "$LOG_FILE" ] || return 0
  local dir; dir=$(dirname "$LOG_FILE")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# ----------------------------------------------------------------- usage ----

usage() {
  cat <<'EOF'
clockodo.sh — record work hours in Clockodo

USAGE
  clockodo.sh <command> [options]

COMMANDS
  log          Record a completed time entry (subject to the guards)
  guard        Show what the guards think about a given day
  list         List entries for a day / range, with totals
  ids          Print IDs of customers, projects, services or users
  delete       Delete an entry by ID
  check        Verify credentials and print the resolved config
  init         Write a config file template
  cache-clear  Drop cached holiday/absence/user lookups
  help         Show this help

LOG
  clockodo.sh log 09:00-17:00 "Refactored the import job"
  clockodo.sh log --since 09:00 --duration 2h30m --alias acme
  clockodo.sh log --date yesterday --since 13:00 --until 17:45 -t "Meeting"
  clockodo.sh log --random-start 07:30-09:00 --duration 8h "Regular work"
  clockodo.sh log --date 2026-08-14 -s 09:00 -u 12:00 -p 12345 --dry-run

  -s, --since TIME       Start: HH:MM, or "YYYY-MM-DD HH:MM"
  -u, --until TIME       End (may be earlier than start = past midnight)
  -D, --duration DUR     Instead of --until: 90m, 2h, 1h30m, 1.5h
  -d, --date DATE        Date for bare HH:MM times: YYYY-MM-DD,
                         today, yesterday, or -N for N days ago
  -t, --text TEXT        Description (bare arguments also become text)
  -a, --alias NAME       Use a customer/project/service alias from the config
  -c, --customer ID      Customer ID       (overrides alias/default)
  -p, --project ID       Project ID        (overrides alias/default)
  -S, --service ID       Service ID        (overrides alias/default)
  -b, --billable 0|1|2   0 = no, 1 = yes, 2 = already billed
  -n, --dry-run          Print the request instead of sending it
  -f, --force            Ignore all guards and book the entry anyway
  -q, --quiet            Print nothing unless something needs attention —
                         use this from cron so mail only arrives on trouble
      --break DUR        Break length for this run (0 = none)
      --break-at HH:MM   When the break starts
      --no-break         Book one contiguous entry
      --on-existing M    Override CLOCKODO_ON_EXISTING_ENTRIES for this run
                         (any | overlap | off)

  A bare argument of the form HH:MM-HH:MM sets --since and --until at once.

RANDOMISED START
  -r, --random-start [RANGE]   Pick the start time at random inside RANGE,
                               on a step boundary. Without RANGE, uses
                               CLOCKODO_RANDOM_START from the config.
      --random-step MINUTES    Step size (default CLOCKODO_RANDOM_STEP, 15)
      --seed N                 Reproducible choice, for testing

  clockodo.sh log -r 07:30-09:00 -D 8h "Regular work"
      -> starts at one of 07:30, 07:45, 08:00 … 09:00, ends 8h later

  The range is rounded inward onto the step grid, so with the default
  15-minute step a start can only ever land on :00, :15, :30 or :45. This
  needs --duration, since the end time moves with the start. An explicit
  --since always wins. With CLOCKODO_RANDOM_START set in the config, plain
  `clockodo.sh log --duration 8h` randomises on its own.

BREAKS
  Above CLOCKODO_BREAK_AFTER (6h by default) the day is booked as two
  entries with an unrecorded gap, rather than one long block:

    clockodo.sh log -r 07:30-09:00 --duration 7h30m "Work"
    -> 07:45–12:00 and 12:30–15:45   (7h30m recorded, 30m break at 12:00)

  With --duration the break EXTENDS the day: the duration is working time
  and the end moves out by the break. With --until it is carved OUT of the
  span you gave. If the configured break time does not fit inside the day
  — a late start, a short day — it falls back to roughly halfway through.

  Configure with CLOCKODO_BREAK_DURATION, CLOCKODO_BREAK_AT and
  CLOCKODO_BREAK_AFTER; override per run with --break / --break-at /
  --no-break.

GUARDS
  Before writing anything, `log` checks that the day is worth booking and
  exits without an entry (status 0, so cron stays quiet) if it is not:

    working day       weekday not in CLOCKODO_WORKDAYS      -> skip
    holiday           in your Clockodo nonbusiness calendar -> skip
    absence           holiday / sick leave / … booked       -> skip
    existing entries  day already has entries of yours      -> skip

  Each is switched on or off in the config. Inspect them with:

    clockodo.sh guard                  today
    clockodo.sh guard --date 2026-12-25
    clockodo.sh guard --types          absence type numbers

LIST
  clockodo.sh list                      today
  clockodo.sh list --date yesterday
  clockodo.sh list --week               current week (Mon-Sun)
  clockodo.sh list --month              current month
  clockodo.sh list --from 2026-08-01 --to 2026-08-15
  clockodo.sh list --week --json        raw JSON

IDS
  clockodo.sh ids                       customers, projects and services
  clockodo.sh ids projects              just the projects
  clockodo.sh ids services
  clockodo.sh ids customers|projects|services|users
  clockodo.sh ids projects --customer 12345    only that customer's projects
  clockodo.sh ids projects relaunch            substring search

GLOBAL
  --config FILE          Config file (default ~/.config/clockodo/config,
                         or $CLOCKODO_CONFIG)
  --refresh              Ignore cached holiday/absence/user lookups
  -v, --verbose          Show HTTP requests
  --version              Print version

EXIT CODES
  0  entry recorded, or skipped by a guard (CLOCKODO_SKIP_EXIT_CODE)
  1  error: bad arguments, bad credentials, API refused the entry,
     or a first run that just wrote an example config for you to fill in
EOF
}

# ---------------------------------------------------------------- config ----

CONFIG_TEMPLATE='# clockodo.sh configuration — this file is sourced by bash.
# Keep it private:  chmod 600 this file.
#
# Every setting is commented out and shows its built-in default. Uncomment
# only what you want to change. The two credentials at the top are the
# minimum needed to get going.

# --- credentials -------------------------------------------------------
# Your Clockodo login email, and the API key from
# Clockodo -> your name (top right) -> "Personal data" -> "API key".
#CLOCKODO_EMAIL="you@example.com"
#CLOCKODO_API_KEY=""

# Identifies this script to Clockodo. Name and email together must be
# 50 characters or fewer.
#CLOCKODO_APP_NAME="clockodo.sh"

# --- defaults used when no flag or alias supplies them ------------------
# Run `clockodo.sh ids` to list customers, projects and services with
# their IDs.
#CLOCKODO_CUSTOMERS_ID=""
#CLOCKODO_PROJECTS_ID=""
#CLOCKODO_SERVICES_ID=""
#CLOCKODO_BILLABLE="1"          # 0 = not billable, 1 = billable, 2 = billed

# Time zone your HH:MM times are written in (times are sent to the API in
# UTC). Leave empty to use the machine time zone.
#CLOCKODO_TZ="Europe/Vienna"

# --- randomised start times --------------------------------------------
# So that an automated daily entry does not read as "09:00:00 sharp, every
# single day". With a range set here, `clockodo.sh log --duration 8h`
# starts somewhere inside it, on a step boundary:
#
#   CLOCKODO_RANDOM_START="07:30-09:00"  ->  07:30, 07:45, 08:00 … 09:00
#
# Leave empty to always start exactly when you say. --since always wins
# over this, and --random-start turns it on for a single run.
#CLOCKODO_RANDOM_START=""
#CLOCKODO_RANDOM_STEP="15"      # minutes; 15 = quarter-hour boundaries

# --- breaks -------------------------------------------------------------
# Above a threshold, the day is booked as two entries with an unrecorded
# gap between them, instead of one long block. With the defaults, a 7h30m
# day starting at 07:45 becomes 07:45-12:00 and 12:30-15:45.
#
# With --duration, the break EXTENDS the day: --duration 7h30m books 7h30m
# of work and ends a further 30 minutes later. With --until, the break is
# carved OUT of the span: 09:00-17:00 books 7h30m of work in two entries.
#
#CLOCKODO_BREAK_DURATION="30m"  # empty or 0 disables breaks entirely
#CLOCKODO_BREAK_AT="12:00"      # when it starts; empty = halfway through
#CLOCKODO_BREAK_AFTER="6h"      # only break when work exceeds this
#
# If the configured time does not fit inside the day being booked — a late
# start, a short day, a randomised start that lands past it — the break
# falls back to roughly halfway through, rounded to the step size.

# --- guards: when should `log` refuse to book anything? -----------------
# Guards make the script safe to run unattended (cron, a login hook, a
# git post-commit hook). When a guard trips, `log` prints the reason and
# exits 0 without writing anything. --force bypasses all of them, and
# `clockodo.sh guard` shows what each one thinks about a given day.

# Do not log on non-working days. CLOCKODO_WORKDAYS uses ISO weekday
# numbers, Monday = 1: "1-5" is Mon-Fri, "1,2,4" is Mon/Tue/Thu.
#CLOCKODO_SKIP_NON_WORKDAYS=1
#CLOCKODO_WORKDAYS="1-5"

# Do not log on public/company holidays from your Clockodo nonbusiness
# calendar. Half holidays are logged with a warning rather than skipped.
#CLOCKODO_SKIP_HOLIDAYS=1
#CLOCKODO_NONBUSINESSGROUPS_ID=""   # empty = the group your user belongs to

# Do not log on days you have an absence booked in Clockodo.
#CLOCKODO_SKIP_ABSENCES=1
# Which absence states count. 0 = requested, 1 = approved, 2 = declined,
# 3 = approval cancelled, 4 = request cancelled.
#CLOCKODO_ABSENCE_STATUSES="0,1"
# Absence types that should NOT stop you logging: 8 = home office,
# 9 = work out of office. See `clockodo.sh guard --types`.
#CLOCKODO_ABSENCE_IGNORE_TYPES="8,9"

# What to do when the day already has entries of yours:
#   any      skip if the day has any entry at all
#   overlap  skip only if the new entry overlaps an existing one
#   off      never check
#CLOCKODO_ON_EXISTING_ENTRIES="any"

# Exit code used when a guard skips the entry. 0 keeps cron quiet; use
# something else if you want a wrapper script to notice.
#CLOCKODO_SKIP_EXIT_CODE=0

# Your own user ID. Left empty it is looked up from your email once and
# cached; set it to save that lookup.
#CLOCKODO_USERS_ID=""

# --- aliases -----------------------------------------------------------
# Shortcuts for combinations you use often, selected with --alias NAME.
# Only the parts you set are overridden; the rest fall back to the
# defaults above. Alias names may contain letters, digits and underscores.
#
# ALIAS_acme_CUSTOMERS_ID=11111
# ALIAS_acme_PROJECTS_ID=22222
# ALIAS_acme_SERVICES_ID=33333
# ALIAS_acme_BILLABLE=1
# ALIAS_acme_TEXT="Development"
#
# ALIAS_admin_SERVICES_ID=44444
# ALIAS_admin_BILLABLE=0
'

load_config() {
  # Values already present in the environment win over the config file.
  local env_email="${CLOCKODO_EMAIL:-}" env_key="${CLOCKODO_API_KEY:-}"
  local env_app="${CLOCKODO_APP_NAME:-}" env_tz="${CLOCKODO_TZ:-}"

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    local perms
    perms=$(ls -l "$CONFIG_FILE" 2>/dev/null | cut -c1-10)
    case "$perms" in
      *r??r*|*r?????r*) warn "$CONFIG_FILE is readable by others — run: chmod 600 \"$CONFIG_FILE\"" ;;
    esac
  fi

  : "${CLOCKODO_EMAIL:=}"
  : "${CLOCKODO_API_KEY:=}"
  : "${CLOCKODO_APP_NAME:=clockodo.sh}"
  : "${CLOCKODO_CUSTOMERS_ID:=}"
  : "${CLOCKODO_PROJECTS_ID:=}"
  : "${CLOCKODO_SERVICES_ID:=}"
  : "${CLOCKODO_BILLABLE:=1}"
  : "${CLOCKODO_TZ:=}"
  : "${CLOCKODO_USERS_ID:=}"
  [ -n "${CLOCKODO_LOG:-}" ] && [ -z "$LOG_FILE" ] && LOG_FILE="$CLOCKODO_LOG"
  : "${CLOCKODO_RANDOM_START:=}"
  : "${CLOCKODO_RANDOM_STEP:=15}"
  : "${CLOCKODO_BREAK_DURATION:=30m}"
  : "${CLOCKODO_BREAK_AT:=12:00}"
  : "${CLOCKODO_BREAK_AFTER:=6h}"
  : "${CLOCKODO_SKIP_NON_WORKDAYS:=1}"
  : "${CLOCKODO_WORKDAYS:=1-5}"
  : "${CLOCKODO_SKIP_HOLIDAYS:=1}"
  : "${CLOCKODO_NONBUSINESSGROUPS_ID:=}"
  : "${CLOCKODO_SKIP_ABSENCES:=1}"
  : "${CLOCKODO_ABSENCE_STATUSES:=0,1}"
  : "${CLOCKODO_ABSENCE_IGNORE_TYPES:=8,9}"
  : "${CLOCKODO_ON_EXISTING_ENTRIES:=any}"
  : "${CLOCKODO_SKIP_EXIT_CODE:=0}"

  [ -n "$env_email" ] && CLOCKODO_EMAIL="$env_email"
  [ -n "$env_key" ]   && CLOCKODO_API_KEY="$env_key"
  [ -n "$env_app" ]   && CLOCKODO_APP_NAME="$env_app"
  [ -n "$env_tz" ]    && CLOCKODO_TZ="$env_tz"

  if [ -n "$CLOCKODO_TZ" ]; then export TZ="$CLOCKODO_TZ"; fi
  return 0
}

# Align columns separated by the unit-separator character (0x1f).
SEP=$'\037'
tabulate() { awk -F'\037' '
  { for (i = 1; i <= NF; i++) { row[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
    if (NF > maxf) maxf = NF; n = NR }
  END { for (r = 1; r <= n; r++) { line = ""
          for (i = 1; i <= maxf; i++)
            line = line (i < maxf ? sprintf("%-*s  ", w[i], row[r, i]) : row[r, i])
          sub(/ +$/, "", line); print line } }'
}

require_credentials() {
  [ -n "$CLOCKODO_EMAIL" ] && [ -n "$CLOCKODO_API_KEY" ] && return 0
  die "no credentials — uncomment CLOCKODO_EMAIL and CLOCKODO_API_KEY in $CONFIG_FILE (the key is under Clockodo -> your name -> \"Personal data\" -> \"API key\")"
}

write_config_template() {
  local dir; dir=$(dirname "$CONFIG_FILE")
  mkdir -p "$dir" || die "cannot create $dir"
  printf '%s' "$CONFIG_TEMPLATE" > "$CONFIG_FILE" || die "cannot write $CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

cmd_init() {
  if [ -f "$CONFIG_FILE" ]; then
    info "Config already exists: $CONFIG_FILE"
    exit 0
  fi
  write_config_template
  info "Created $CONFIG_FILE"
  info ""
  info "Next: uncomment CLOCKODO_EMAIL and CLOCKODO_API_KEY in it (the key is"
  info "under Clockodo -> your name -> \"Personal data\" -> \"API key\"), then:"
  info "  clockodo.sh ids"
}

# On a first run with no config anywhere, write the commented example and
# stop, rather than failing with a bare "no API key". Skipped when the
# credentials come from the environment instead.
ensure_config() {
  [ -f "$CONFIG_FILE" ] && return 0
  if [ -n "${CLOCKODO_EMAIL:-}" ] && [ -n "${CLOCKODO_API_KEY:-}" ]; then
    return 0   # configured through the environment; no file needed
  fi
  write_config_template
  info "No configuration found, so an example was written to:"
  info "  $CONFIG_FILE"
  info ""
  info "Everything in it is commented out. Uncomment at least CLOCKODO_EMAIL"
  info "and CLOCKODO_API_KEY — the key is under Clockodo -> your name ->"
  info "\"Personal data\" -> \"API key\" — then run this command again."
  exit 1
}

# ------------------------------------------------------------------ time ----

# BSD (macOS) and GNU date take different flags; detect once.
if date -j -f '%Y-%m-%d %H:%M:%S' '2020-01-01 00:00:00' '+%s' >/dev/null 2>&1; then
  DATE_FLAVOR=bsd
else
  DATE_FLAVOR=gnu
fi

# "YYYY-MM-DD HH:MM:SS" (local) -> epoch seconds
to_epoch() {
  if [ "$DATE_FLAVOR" = bsd ]; then
    date -j -f '%Y-%m-%d %H:%M:%S' "$1" '+%s' 2>/dev/null
  else
    date -d "$1" '+%s' 2>/dev/null
  fi
}

# epoch -> format, in UTC
epoch_utc() { # epoch format
  if [ "$DATE_FLAVOR" = bsd ]; then
    date -u -r "$1" "+$2"
  else
    date -u -d "@$1" "+$2"
  fi
}

# epoch -> format, in local time
epoch_local() { # epoch format
  if [ "$DATE_FLAVOR" = bsd ]; then
    date -r "$1" "+$2"
  else
    date -d "@$1" "+$2"
  fi
}

# ISO-8601 UTC ("2026-08-17T07:00:00Z") -> epoch seconds
iso_to_epoch() {
  if [ "$DATE_FLAVOR" = bsd ]; then
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s'
  else
    date -u -d "$1" '+%s'
  fi
}

# Resolve a date word to YYYY-MM-DD: today, yesterday, tomorrow, -N, YYYY-MM-DD
resolve_date() {
  local d="$1"
  case "$d" in
    ''|today)   epoch_local "$(date '+%s')" '%Y-%m-%d' ;;
    yesterday)  shift_day -1 ;;
    tomorrow)   shift_day 1 ;;
    -[0-9]*)    shift_day "$d" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf '%s' "$d" ;;
    *) die "unrecognised date: '$d' (use YYYY-MM-DD, today, yesterday, or -N)" ;;
  esac
}

shift_day() { # signed number of days
  local days="$1" now
  now=$(date '+%s')
  epoch_local $(( now + days * 86400 )) '%Y-%m-%d'
}

# "2h30m" / "90m" / "1.5h" / "45" -> minutes
parse_duration() {
  local d="$1" mins=0 matched=0 h m
  d=$(printf '%s' "$d" | tr 'A-Z' 'a-z' | tr -d ' ')
  case "$d" in
    *h*m)
      h=${d%%h*}; m=${d#*h}; m=${m%m}
      mins=$(awk -v h="$h" -v m="$m" 'BEGIN{printf "%d", h*60+m}'); matched=1 ;;
    *h)
      h=${d%h}
      mins=$(awk -v h="$h" 'BEGIN{printf "%d", h*60}'); matched=1 ;;
    *m)
      m=${d%m}
      mins=$(awk -v m="$m" 'BEGIN{printf "%d", m}'); matched=1 ;;
    *[0-9])
      mins=$(awk -v m="$d" 'BEGIN{printf "%d", m}'); matched=1 ;;
  esac
  [ "$matched" = 1 ] || die "cannot parse duration: '$1' (try 90m, 2h, 1h30m)"
  [ "$mins" -gt 0 ] 2>/dev/null || die "duration must be positive: '$1'"
  printf '%s' "$mins"
}

# A time argument is either "HH:MM[:SS]" (combined with --date) or a full
# "YYYY-MM-DD HH:MM[:SS]". Returns epoch seconds.
time_to_epoch() { # time_arg default_date
  local t="$1" day="$2" e
  t=$(printf '%s' "$t" | sed 's/^ *//; s/ *$//')
  case "$t" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      # full timestamp, normalise the separator and seconds
      t=$(printf '%s' "$t" | tr 'T' ' ')
      case "$t" in
        *:*:*) : ;;
        *:*)   t="$t:00" ;;
        *)     t="$t 00:00:00" ;;
      esac
      ;;
    *:*:*) t="$day $t" ;;
    *:*)   t="$day $t:00" ;;
    [0-9]|[0-9][0-9])           t="$day $(printf '%02d' "$t"):00:00" ;;
    [0-9][0-9][0-9][0-9])       t="$day ${t:0:2}:${t:2:2}:00" ;;
    *) die "cannot parse time: '$1' (try 09:00 or \"2026-08-17 09:00\")" ;;
  esac
  e=$(to_epoch "$t") || true
  [ -n "$e" ] || die "cannot parse time: '$1'"
  printf '%s' "$e"
}

fmt_hours() { # minutes -> "7.50 h (7h 30m)"
  awk -v m="$1" 'BEGIN{printf "%.2f h (%dh %02dm)", m/60, int(m/60), m%60}'
}

# "HH:MM" -> minutes since midnight
hm_to_min() {
  case "$1" in
    [0-9][0-9]:[0-9][0-9]|[0-9]:[0-9][0-9]) : ;;
    *) die "expected HH:MM, got '$1'" ;;
  esac
  local h="${1%%:*}" m="${1##*:}"
  h=${h#0}; m=${m#0}
  printf '%s' $(( ${h:-0} * 60 + ${m:-0} ))
}

min_to_hm() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# ---------------------------------------------------------------- random ----

RAND_SEED=''

# A uniform 15-bit number, from /dev/urandom where available so that runs
# started by cron within the same second do not correlate.
rand15() {
  local v=''
  if [ -r /dev/urandom ]; then
    v=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' \n') || v=''
  fi
  # $RANDOM is the fallback, not the default: bash 5.1+ reseeds it per
  # subshell, and this runs inside command substitutions.
  case "$v" in ''|*[!0-9]*) v=$RANDOM ;; esac
  printf '%s' $(( v % 32768 ))
}

# Uniform integer in [0, n) — rejection sampling, so slot counts that do not
# divide 32768 (7 quarter-hours, say) stay evenly distributed.
rand_below() {
  local n="$1" limit r
  [ "$n" -gt 1 ] || { printf '0'; return; }

  # --seed: reproducible. awk's own srand()/rand() is not portable enough
  # for this (mawk ignores the seed across processes), so this is a plain
  # MINSTD step instead — all products stay inside double precision.
  if [ -n "$RAND_SEED" ]; then
    case "$RAND_SEED" in ''|*[!0-9]*) die "--seed takes a whole number" ;; esac
    awk -v s="$RAND_SEED" -v n="$n" 'BEGIN{
      x = s % 2147483647; if (x <= 0) x += 2147483646
      x = (x * 16807) % 2147483647
      x = (x * 16807) % 2147483647
      # scale by the high bits: 16807 is a multiple of 7, so "x % n" would
      # collapse to the same slot every time for a 7-slot quarter-hour range
      r = int(x / 2147483647 * n)
      if (r >= n) r = n - 1
      printf "%d", r
    }'
    return
  fi

  limit=$(( 32768 - (32768 % n) ))
  while :; do
    r=$(rand15)
    if [ "$r" -lt "$limit" ]; then printf '%s' $(( r % n )); return; fi
  done
}

# "07:30-09:00" + step -> a random start time on a step boundary inside it.
# The range is rounded inward to the step grid, so a 15-minute step can only
# ever produce :00, :15, :30 or :45.
random_start_time() { # RANGE STEP_MINUTES
  local range="$1" step="$2" lo hi slots pick
  case "$range" in
    *-*) : ;;
    *) die "random start range must look like 07:30-09:00 (got '$range')" ;;
  esac
  case "$step" in ''|*[!0-9]*) die "random step must be a whole number of minutes (got '$2')" ;; esac
  [ "$step" -gt 0 ] || die "random step must be greater than 0"

  lo=$(hm_to_min "${range%%-*}")
  hi=$(hm_to_min "${range##*-}")
  [ "$hi" -ge "$lo" ] || die "random start range ends before it begins: $range"

  # round inward onto the grid
  if [ $(( lo % step )) -ne 0 ]; then lo=$(( lo + step - lo % step )); fi
  hi=$(( hi - hi % step ))
  [ "$hi" -ge "$lo" ] || die "no $step-minute boundary inside $range"

  slots=$(( (hi - lo) / step + 1 ))
  pick=$(rand_below "$slots")
  # chosen time, slot count and the effective grid, for the caller to split
  printf '%s%s%s%s%s–%s' "$(min_to_hm $(( lo + pick * step )))" "$SEP" \
    "$slots" "$SEP" "$(min_to_hm "$lo")" "$(min_to_hm "$hi")"
}

# ------------------------------------------------------------------ http ----

VERBOSE=0

# Performs the request and prints "<status>\n<body>". Never exits on an HTTP
# error — callers decide what to do (see api / api_first). The status has to
# travel through stdout because callers run this in a command substitution,
# where a variable assignment would not survive.
api_raw() { # METHOD PATH [JSON_BODY]
  require_credentials
  local method="$1" path="$2" body="${3:-}"
  local url="$API_BASE$path"
  local attempt=1 max=3 out code resp

  while :; do
    local args=(--silent --show-error --location --max-time 45
      -w '\n%{http_code}'
      -X "$method"
      -H "X-ClockodoApiUser: $CLOCKODO_EMAIL"
      -H "X-ClockodoApiKey: $CLOCKODO_API_KEY"
      -H "X-Clockodo-External-Application: ${CLOCKODO_APP_NAME};${CLOCKODO_EMAIL}"
      -H 'Accept: application/json')
    if [ -n "$body" ]; then
      args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi

    [ "$VERBOSE" = 1 ] && info "${C_DIM}> $method $url${body:+ $body}${C_OFF}"

    out=$(curl "${args[@]}" "$url") || die "request failed (curl exit $?)"
    code=${out##*$'\n'}
    resp=${out%$'\n'*}

    [ "$VERBOSE" = 1 ] && info "${C_DIM}< $code $resp${C_OFF}"

    case "$code" in
      429|5*)
        if [ "$attempt" -lt "$max" ]; then
          local wait=$(( attempt * 3 ))
          warn "HTTP $code — retrying in ${wait}s ($attempt/$max)"
          sleep "$wait"; attempt=$(( attempt + 1 )); continue
        fi ;;
    esac
    printf '%s\n%s' "$code" "$resp"
    return 0
  done
}

api() { # METHOD PATH [JSON_BODY] ; prints body, exits on any HTTP error
  local out code resp
  out=$(api_raw "$@")
  code=${out%%$'\n'*}; resp=${out#*$'\n'}
  case "$code" in
    2*) printf '%s' "$resp"; return 0 ;;
    401|403) die "authentication failed ($code). Check CLOCKODO_EMAIL and CLOCKODO_API_KEY in $CONFIG_FILE" ;;
    *) die "HTTP $code on $2: $(api_error "$resp")" ;;
  esac
}

# Clockodo versions individual resources (…/v2/entries but …/v4/absences) and
# bumps them over time. Try the known paths newest-first and keep the first
# one this account's API actually answers.
api_first() { # METHOD PATH...
  local method="$1"; shift
  local path out code resp last=''
  for path in "$@"; do
    out=$(api_raw "$method" "$path")
    code=${out%%$'\n'*}; resp=${out#*$'\n'}
    case "$code" in
      2*) printf '%s' "$resp"; return 0 ;;
      401|403) die "authentication failed ($code). Check CLOCKODO_EMAIL and CLOCKODO_API_KEY in $CONFIG_FILE" ;;
      404|400|405) last="$resp"; continue ;;
      *) die "HTTP $code on $path: $(api_error "$resp")" ;;
    esac
  done
  die "none of these endpoints answered: $* — last response: $(api_error "$last")"
}

api_error() {
  printf '%s' "$1" | jq -r '
    if type == "object" then
      (.error // .message // .) |
      if type == "object" then (.message // (to_entries | map("\(.key): \(.value)") | join("; ")))
      else tostring end
    else tostring end' 2>/dev/null || printf '%s' "$1"
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# ----------------------------------------------------------------- cache ----
# Holiday calendars and absences barely change, and the guards would
# otherwise cost three extra API calls on every single log. Cached files
# carry their expiry as the first line.

CACHE_DIR="${CLOCKODO_CACHE_DIR:-$HOME/.cache/clockodo}"
NO_CACHE=0

cache_read() { # key max_age_seconds
  [ "$NO_CACHE" = 1 ] && return 1
  local f="$CACHE_DIR/$1.json" stamp now
  [ -f "$f" ] || return 1
  IFS= read -r stamp < "$f" || return 1
  case "$stamp" in *[!0-9]*|'') return 1 ;; esac
  now=$(date '+%s')
  [ $(( now - stamp )) -lt "$2" ] || return 1
  tail -n +2 "$f"
}

cache_write() { # key json
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  { date '+%s'; printf '%s\n' "$2"; } > "$CACHE_DIR/$1.json" 2>/dev/null || true
}

cmd_cache_clear() {
  rm -f "$CACHE_DIR"/*.json 2>/dev/null || true
  info "Cleared $CACHE_DIR"
}

# ------------------------------------------------------------------ user ----

USER_ID=''
USER_NONBUSINESS_GROUP=''

resolve_user() {
  [ -n "$USER_ID" ] && return 0

  local cached
  if cached=$(cache_read "user-$(printf '%s' "$CLOCKODO_EMAIL" | tr -c 'A-Za-z0-9' '_')" 604800); then
    USER_ID=$(printf '%s' "$cached" | jq -r '.id // empty')
    USER_NONBUSINESS_GROUP=$(printf '%s' "$cached" | jq -r '.group // empty')
    [ -n "$USER_ID" ] && return 0
  fi

  if [ -n "${CLOCKODO_USERS_ID:-}" ]; then
    USER_ID="$CLOCKODO_USERS_ID"
  fi

  local resp me
  resp=$(api_first GET /v3/users /v2/users /users)
  me=$(printf '%s' "$resp" | jq -c --arg email "$CLOCKODO_EMAIL" --arg id "${USER_ID:-}" '
    (.users // [])
    | map(select( ($id != "" and ((.id|tostring) == $id))
                  or ($id == "" and ((.email // "") | ascii_downcase) == ($email | ascii_downcase)) ))
    | first
    | if . == null then empty
      else {id: .id, group: ((.nonbusinessgroups_id // .nonbusinessGroupsId // "") | tostring)}
      end')

  [ -n "$me" ] || die "could not find a Clockodo user matching $CLOCKODO_EMAIL — set CLOCKODO_USERS_ID in $CONFIG_FILE (see: clockodo.sh ids users)"
  USER_ID=$(printf '%s' "$me" | jq -r '.id')
  USER_NONBUSINESS_GROUP=$(printf '%s' "$me" | jq -r '.group | if . == null then "" else tostring end')
  cache_write "user-$(printf '%s' "$CLOCKODO_EMAIL" | tr -c 'A-Za-z0-9' '_')" "$me"
}

# ---------------------------------------------------------------- guards ----
# Each guard prints a human-readable reason and returns 1 when the day
# should be skipped, or returns 0 to allow logging.

GUARD_REASON=''

# Is this weekday a working day? CLOCKODO_WORKDAYS is a list like "1-5" or
# "1,2,3,4,5" over ISO weekday numbers (Monday = 1).
guard_workday() { # YYYY-MM-DD
  [ "$CLOCKODO_SKIP_NON_WORKDAYS" = 1 ] || return 0
  local dow part lo hi
  dow=$(epoch_local "$(to_epoch "$1 12:00:00")" '%u')
  local oldifs="$IFS"; IFS=','
  for part in $CLOCKODO_WORKDAYS; do
    IFS="$oldifs"
    case "$part" in
      *-*) lo=${part%%-*}; hi=${part##*-}
           if [ "$dow" -ge "$lo" ] && [ "$dow" -le "$hi" ]; then return 0; fi ;;
      *)   if [ "$dow" = "$part" ]; then return 0; fi ;;
    esac
    IFS=','
  done
  IFS="$oldifs"
  GUARD_REASON="$(epoch_local "$(to_epoch "$1 12:00:00")" '%A') is not a working day (CLOCKODO_WORKDAYS=$CLOCKODO_WORKDAYS)"
  return 1
}

# Public / company holidays from Clockodo's nonbusiness day calendar.
guard_holiday() { # YYYY-MM-DD
  [ "$CLOCKODO_SKIP_HOLIDAYS" = 1 ] || return 0
  local year="${1%%-*}" group="${CLOCKODO_NONBUSINESSGROUPS_ID:-}" days key hit

  if [ -z "$group" ]; then
    resolve_user
    group="$USER_NONBUSINESS_GROUP"
  fi
  key="holidays-$year-${group:-all}"

  if ! days=$(cache_read "$key" 2592000); then
    local q="?year=$year"
    [ -n "$group" ] && [ "$group" != 0 ] && q="$q&nonbusinessgroups_id=$group"
    days=$(api_first GET "/v2/nonbusinessDays$q" "/nonbusinessdays$q" \
      | jq -c '[ (.nonbusinessDays // .nonbusinessdays // [])[]
                 | {date: (.date // ""), name: (.name // "Holiday"),
                    half: ((.half_day // .halfDay // 0) | if . == true then 1 elif . == false then 0 else . end)} ]')
    cache_write "$key" "$days"
  fi

  hit=$(printf '%s' "$days" | jq -r --arg d "$1" 'map(select(.date == $d)) | first | if . == null then "" else "\(.half)\t\(.name)" end')
  [ -n "$hit" ] || return 0

  case "$hit" in
    1*) warn "${hit#*	} is a half holiday — logging anyway"; return 0 ;;
    *)  GUARD_REASON="public holiday: ${hit#*	}"; return 1 ;;
  esac
}

# Approved or requested absences (holiday, sick leave, …) covering the day.
guard_absence() { # YYYY-MM-DD
  [ "$CLOCKODO_SKIP_ABSENCES" = 1 ] || return 0
  resolve_user
  local year="${1%%-*}"
  local key="absences-$year-$USER_ID" list hit

  if ! list=$(cache_read "$key" 21600); then
    list=$(api_first GET "/v4/absences?year=$year" "/v3/absences?year=$year" "/v2/absences?year=$year" \
      | jq -c --arg uid "$USER_ID" '[ (.absences // [])[]
          | {users_id: ((.users_id // .usersId)|tostring),
             since: (.date_since // .dateSince // ""),
             until: (.date_until // .dateUntil // .date_since // .dateSince // ""),
             status: ((.status // 1)|tonumber),
             type: ((.type // 1)|tonumber)}
          | select(.users_id == $uid) ]')
    cache_write "$key" "$list"
  fi

  hit=$(printf '%s' "$list" | jq -r --arg d "$1" \
      --arg st "$CLOCKODO_ABSENCE_STATUSES" --arg ig "$CLOCKODO_ABSENCE_IGNORE_TYPES" '
    ($st | split(",") | map(select(length>0) | tonumber)) as $stat |
    ($ig | split(",") | map(select(length>0) | tonumber)) as $ignore |
    map(select(.since <= $d and .until >= $d
               and (.status as $s | $stat | index($s))
               and ((.type as $t | $ignore | index($t)) | not)))
    | first | if . == null then "" else "\(.type)" end')
  [ -n "$hit" ] || return 0

  GUARD_REASON="you are absent that day ($(absence_type_name "$hit"))"
  return 1
}

absence_type_name() {
  case "$1" in
    1) printf 'holiday' ;;            2) printf 'special leave' ;;
    3) printf 'overtime reduction' ;; 4) printf 'sick day' ;;
    5) printf "child's sick day" ;;   6) printf 'further education' ;;
    7) printf 'maternity protection' ;; 8) printf 'home office' ;;
    9) printf 'work out of office' ;; 10) printf 'unpaid special leave' ;;
    11) printf 'unpaid sick day' ;;   12) printf "unpaid child's sick day" ;;
    13) printf 'quarantine' ;;        14) printf 'military service' ;;
    15) printf 'sick with benefit' ;; *) printf 'absence type %s' "$1" ;;
  esac
}

# Entries this user already booked on that day.
guard_existing_entries() { # YYYY-MM-DD [since_epoch until_epoch]
  case "$CLOCKODO_ON_EXISTING_ENTRIES" in
    off|'') return 0 ;;
    any|overlap) : ;;
    *) die "CLOCKODO_ON_EXISTING_ENTRIES must be any, overlap or off (got '$CLOCKODO_ON_EXISTING_ENTRIES')" ;;
  esac
  resolve_user

  local day_start day_end entries count
  day_start=$(to_epoch "$1 00:00:00")
  day_end=$(( day_start + 86400 ))
  entries=$(api GET "/v2/entries?time_since=$(urlenc "$(epoch_utc "$day_start" '%Y-%m-%dT%H:%M:%SZ')")&time_until=$(urlenc "$(epoch_utc "$day_end" '%Y-%m-%dT%H:%M:%SZ')")&filter%5Busers_id%5D=$USER_ID" \
    | jq -c '[ (.entries // [])[] ]')

  count=$(printf '%s' "$entries" | jq 'length')
  [ "$count" = 0 ] && return 0

  if [ "$CLOCKODO_ON_EXISTING_ENTRIES" = any ]; then
    local secs
    secs=$(printf '%s' "$entries" | jq -r '[ .[] | (.duration // 0) ] | add // 0')
    GUARD_REASON="$count entr$(plural "$count" y ies) already booked on $1$(awk -v s="$secs" 'BEGIN{if (s>0) printf " (%.2f h)", s/3600}')"
    return 1
  fi

  # overlap mode: only refuse when the new range collides with an existing one
  [ $# -ge 3 ] || return 0
  local es eu es_e eu_e
  while IFS="$SEP" read -r es eu; do
    [ -n "$es" ] || continue
    es_e=$(iso_to_epoch "$es")
    if [ -n "$eu" ]; then eu_e=$(iso_to_epoch "$eu"); else eu_e=$(date '+%s'); fi
    if [ "$2" -lt "$eu_e" ] && [ "$3" -gt "$es_e" ]; then
      GUARD_REASON="overlaps an existing entry ($(epoch_local "$es_e" '%H:%M')–$(epoch_local "$eu_e" '%H:%M'))"
      return 1
    fi
  done <<EOF
$(printf '%s' "$entries" | jq -r --arg s "$SEP" '.[] | [.time_since, (.time_until // "")] | join($s)')
EOF
  return 0
}

plural() { if [ "$1" = 1 ]; then printf '%s' "$2"; else printf '%s' "$3"; fi; }

# Runs every enabled guard. Returns 1 (with GUARD_REASON set) to skip.
guards_pass() { # YYYY-MM-DD [since_epoch until_epoch]
  GUARD_REASON=''
  guard_workday "$1" || return 1
  guard_holiday "$1" || return 1
  guard_absence "$1" || return 1
  guard_existing_entries "$@" || return 1
  return 0
}

# ------------------------------------------------------------------- log ----

cmd_log() {
  local since='' until='' duration='' day='' text='' alias=''
  local customers_id='' projects_id='' services_id='' billable=''
  local dry=0 force=0 quiet=0
  local random_range='' random_step='' random_on=0
  local break_dur='' break_at='' no_break=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--since)     since="${2:-}"; shift 2 ;;
      -u|--until)     until="${2:-}"; shift 2 ;;
      -D|--duration)  duration="${2:-}"; shift 2 ;;
      -d|--date)      day="${2:-}"; shift 2 ;;
      -t|--text)      text="${2:-}"; shift 2 ;;
      -a|--alias)     alias="${2:-}"; shift 2 ;;
      -c|--customer)  customers_id="${2:-}"; shift 2 ;;
      -p|--project)   projects_id="${2:-}"; shift 2 ;;
      -S|--service)   services_id="${2:-}"; shift 2 ;;
      -b|--billable)  billable="${2:-}"; shift 2 ;;
      -r|--random-start)
        random_on=1; shift
        # the range is optional — without one, the config's is used
        case "${1:-}" in
          [0-9]*:[0-9]*-[0-9]*:[0-9]*) random_range="$1"; shift ;;
        esac ;;
      --random-step)  random_step="${2:-}"; shift 2 ;;
      --break)        break_dur="${2:-}"; shift 2 ;;
      --break-at)     break_at="${2:-}"; shift 2 ;;
      --no-break)     no_break=1; shift ;;
      --seed)         RAND_SEED="${2:-}"; RANDOM="${2:-0}"; shift 2 ;;
      -n|--dry-run)   dry=1; shift ;;
      -f|--force)     force=1; shift ;;
      -q|--quiet)     quiet=1; shift ;;
      --no-guard)     force=1; shift ;;
      --on-existing)  CLOCKODO_ON_EXISTING_ENTRIES="${2:-}"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      --) shift; text="${text:+$text }$*"; break ;;
      -*) die "unknown option for log: $1" ;;
      [0-9]*:[0-9]*-[0-9]*:[0-9]*)   # 09:00-17:00
        since="${1%%-*}"; until="${1#*-}"; shift ;;
      *) text="${text:+$text }$1"; shift ;;
    esac
  done

  # alias -> defaults
  if [ -n "$alias" ]; then
    case "$alias" in
      *[!A-Za-z0-9_]*) die "alias names may only contain letters, digits and underscores: '$alias'" ;;
    esac
    local found=0 v
    for field in CUSTOMERS_ID PROJECTS_ID SERVICES_ID BILLABLE TEXT; do
      eval "v=\${ALIAS_${alias}_${field}:-}"
      [ -n "$v" ] || continue
      found=1
      case "$field" in
        CUSTOMERS_ID) [ -n "$customers_id" ] || customers_id="$v" ;;
        PROJECTS_ID)  [ -n "$projects_id" ]  || projects_id="$v" ;;
        SERVICES_ID)  [ -n "$services_id" ]  || services_id="$v" ;;
        BILLABLE)     [ -n "$billable" ]     || billable="$v" ;;
        TEXT)         [ -n "$text" ]         || text="$v" ;;
      esac
    done
    [ "$found" = 1 ] || die "alias '$alias' is not defined in $CONFIG_FILE (expected e.g. ALIAS_${alias}_PROJECTS_ID=...)"
  fi

  # config defaults
  [ -n "$customers_id" ] || customers_id="$CLOCKODO_CUSTOMERS_ID"
  [ -n "$projects_id" ]  || projects_id="$CLOCKODO_PROJECTS_ID"
  [ -n "$services_id" ]  || services_id="$CLOCKODO_SERVICES_ID"
  [ -n "$billable" ]     || billable="$CLOCKODO_BILLABLE"

  [ -n "$customers_id" ] || die "no customer ID (set CLOCKODO_CUSTOMERS_ID in $CONFIG_FILE or pass --customer). Find IDs with: clockodo.sh ids customers"
  [ -n "$services_id" ]  || die "no service ID (set CLOCKODO_SERVICES_ID in $CONFIG_FILE or pass --service). Find IDs with: clockodo.sh ids services"
  case "$billable" in 0|1|2) : ;; *) die "--billable must be 0, 1 or 2 (got '$billable')" ;; esac
  case "$customers_id$projects_id$services_id" in *[!0-9]*) die "customer/project/service IDs must be numeric" ;; esac

  # Randomised start: explicit --since always wins; otherwise --random-start,
  # or a CLOCKODO_RANDOM_START in the config, supplies one.
  local randomised=''
  if [ -z "$since" ] && { [ "$random_on" = 1 ] || [ -n "$CLOCKODO_RANDOM_START" ]; }; then
    [ -n "$random_range" ] || random_range="$CLOCKODO_RANDOM_START"
    [ -n "$random_range" ] || die "--random-start needs a range (e.g. --random-start 07:30-09:00) or CLOCKODO_RANDOM_START in $CONFIG_FILE"
    [ -n "$duration" ] || [ -n "$until" ] || die "a randomised start needs --duration (the end time moves with the start)"
    [ -n "$duration" ] || die "a randomised start cannot be combined with a fixed --until — use --duration instead"
    local step="${random_step:-$CLOCKODO_RANDOM_STEP}" picked rest
    picked=$(random_start_time "$random_range" "$step")
    since="${picked%%"$SEP"*}"
    rest="${picked#*"$SEP"}"
    randomised="${C_DIM}picked at random from ${rest#*"$SEP"} in ${step}-minute steps (${rest%%"$SEP"*} options)${C_OFF}"
  elif [ "$random_on" = 1 ] && [ -n "$since" ]; then
    warn "--since $since was given, so the start was not randomised"
  fi

  [ -n "$since" ] || die "no start time. Example: clockodo.sh log 09:00-17:00 \"What I did\""
  [ -n "$until" ] || [ -n "$duration" ] || die "need --until or --duration"

  day=$(resolve_date "${day:-today}")
  local since_e until_e
  since_e=$(time_to_epoch "$since" "$day")
  if [ -n "$until" ]; then
    until_e=$(time_to_epoch "$until" "$day")
    # end before start = the entry ran past midnight
    if [ "$until_e" -le "$since_e" ]; then until_e=$(( until_e + 86400 )); fi
  else
    local dur_mins
    dur_mins=$(parse_duration "$duration")
    until_e=$(( since_e + dur_mins * 60 ))
  fi

  # --- break placement -------------------------------------------------
  # With --duration the break extends the day (the duration is work time);
  # with --until it is carved out of the span you gave.
  local break_mins=0 break_start_e=0 break_end_e=0 break_note=''
  if [ "$no_break" = 0 ]; then
    local want="${break_dur:-$CLOCKODO_BREAK_DURATION}"
    case "$want" in ''|0) want='' ;; esac
    if [ -n "$want" ]; then
      break_mins=$(parse_duration "$want")

      local work_mins threshold
      if [ -n "$duration" ]; then
        work_mins=$(( (until_e - since_e) / 60 ))          # break extends
      else
        work_mins=$(( (until_e - since_e) / 60 - break_mins ))  # break carved out
      fi
      threshold=$(parse_duration "${CLOCKODO_BREAK_AFTER:-6h}")

      if [ "$work_mins" -le "$threshold" ]; then
        break_mins=0                                       # short day, no break
      elif [ "$work_mins" -le 0 ]; then
        die "a ${want} break leaves no working time in that period"
      else
        [ -n "$duration" ] && until_e=$(( since_e + (work_mins + break_mins) * 60 ))

        # preferred start, from --break-at or the config
        local at="${break_at:-$CLOCKODO_BREAK_AT}" fallback=1
        if [ -n "$at" ]; then
          break_start_e=$(time_to_epoch "$at" "$(epoch_local "$since_e" '%Y-%m-%d')")
          break_end_e=$(( break_start_e + break_mins * 60 ))
          # both halves must be worth booking (>= 15 minutes each)
          if [ "$break_start_e" -ge $(( since_e + 900 )) ] &&
             [ "$break_end_e" -le $(( until_e - 900 )) ]; then
            fallback=0
          fi
        fi

        if [ "$fallback" = 1 ]; then
          # roughly halfway through the work, snapped to the step grid
          local step="${random_step:-$CLOCKODO_RANDOM_STEP}" half
          [ "$step" -gt 0 ] 2>/dev/null || step=15
          half=$(( work_mins / 2 ))
          half=$(( (half / step) * step ))
          [ "$half" -ge 15 ] || half=15
          break_start_e=$(( since_e + half * 60 ))
          break_end_e=$(( break_start_e + break_mins * 60 ))
          if [ -n "$at" ]; then
            break_note=" (${at} did not fit, so it sits about halfway)"
          fi
        fi
      fi
    fi
  fi

  local mins=$(( (until_e - since_e) / 60 - break_mins ))
  [ "$mins" -gt 0 ] || die "entry has zero length"
  [ "$mins" -le 1440 ] || warn "entry is $(fmt_hours "$mins") long — is that right?"
  [ "$until_e" -gt "$(date '+%s')" ] && warn "the entry ends in the future"

  # Guards run before anything is written. A tripped guard is a normal,
  # expected outcome (weekend, holiday, day already booked), so it is not
  # an error — it exits with CLOCKODO_SKIP_EXIT_CODE, 0 by default.
  local log_day
  log_day=$(epoch_local "$since_e" '%Y-%m-%d')
  if [ "$force" = 0 ]; then
    if ! guards_pass "$log_day" "$since_e" "$until_e"; then
      if [ "$quiet" = 0 ]; then
        printf '%s—%s skipped %s: %s\n' "$C_YEL" "$C_OFF" "$log_day" "$GUARD_REASON" >&2
      fi
      audit "SKIP   $log_day  $GUARD_REASON"
      exit "$CLOCKODO_SKIP_EXIT_CODE"
    fi
  fi

  # One segment, or two with the break between them.
  local seg_starts seg_ends
  if [ "$break_mins" -gt 0 ]; then
    seg_starts="$since_e $break_end_e"
    seg_ends="$break_start_e $until_e"
  else
    seg_starts="$since_e"
    seg_ends="$until_e"
  fi

  # Summary first, so a --dry-run or a failure still shows the intent.
  if [ "$quiet" = 0 ]; then
    printf '%s%s%s  %s–%s  %s\n' \
      "$C_BLD" "$(epoch_local "$since_e" '%a %Y-%m-%d')" "$C_OFF" \
      "$(epoch_local "$since_e" '%H:%M')" "$(epoch_local "$until_e" '%H:%M')" \
      "$(fmt_hours "$mins")"
    [ -n "$randomised" ] && printf '  %s\n' "$randomised"
    if [ "$break_mins" -gt 0 ]; then
      printf '  %stwo entries, %s min break at %s%s%s\n' "$C_DIM" "$break_mins" \
        "$(epoch_local "$break_start_e" '%H:%M')" "$break_note" "$C_OFF"
    fi
    [ -n "$text" ] && printf '  %s\n' "$text"
  fi

  local i=1 s u payload ids='' resp id
  for s in $seg_starts; do
    u=$(printf '%s' "$seg_ends" | cut -d' ' -f"$i")
    payload=$(jq -nc \
      --argjson customers_id "$customers_id" \
      --argjson services_id "$services_id" \
      --argjson billable "$billable" \
      --arg time_since "$(epoch_utc "$s" '%Y-%m-%dT%H:%M:%SZ')" \
      --arg time_until "$(epoch_utc "$u" '%Y-%m-%dT%H:%M:%SZ')" \
      --arg projects_id "$projects_id" \
      --arg text "$text" '
      {customers_id: $customers_id, services_id: $services_id, billable: $billable,
       time_since: $time_since, time_until: $time_until}
      + (if $projects_id == "" then {} else {projects_id: ($projects_id|tonumber)} end)
      + (if $text == "" then {} else {text: $text} end)')

    if [ "$dry" = 1 ]; then
      printf '%sdry run — would POST %s/v2/entries%s\n' "$C_DIM" "$API_BASE" "$C_OFF"
      printf '%s\n' "$payload" | jq .
      i=$(( i + 1 )); continue
    fi

    # The second POST failing would leave half a day booked, so undo the
    # first rather than leaving something that looks like a real entry.
    local out code
    out=$(api_raw POST /v2/entries "$payload")
    code=${out%%$'\n'*}; resp=${out#*$'\n'}
    case "$code" in
      2*) : ;;
      *)
        if [ -n "$ids" ]; then
          warn "second entry failed — rolling back the first"
          for id in $ids; do api_raw DELETE "/v2/entries/$id" >/dev/null 2>&1 || true; done
        fi
        die "HTTP $code creating the entry: $(api_error "$resp")" ;;
    esac

    id=$(printf '%s' "$resp" | jq -r '.entry.id // empty')
    ids="${ids:+$ids }${id:-?}"
    if [ "$quiet" = 0 ]; then
      printf '%s✓%s %s–%s recorded%s\n' "$C_GRN" "$C_OFF" \
        "$(epoch_local "$s" '%H:%M')" "$(epoch_local "$u" '%H:%M')" "${id:+ (entry $id)}"
    fi
    i=$(( i + 1 ))
  done

  [ "$dry" = 1 ] && return 0
  audit "LOG    $log_day  $(epoch_local "$since_e" '%H:%M')-$(epoch_local "$until_e" '%H:%M')  $(fmt_hours "$mins")$([ "$break_mins" -gt 0 ] && printf ' +%smin break' "$break_mins")  entries: $ids${text:+  $text}"
}

# ------------------------------------------------------------------ list ----

cmd_list() {
  local from='' to='' day='' json=0

  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--date)  day="${2:-}"; shift 2 ;;
      --from)     from=$(resolve_date "${2:-}"); shift 2 ;;
      --to)       to=$(resolve_date "${2:-}"); shift 2 ;;
      --week)
        local today dow
        today=$(date '+%s'); dow=$(epoch_local "$today" '%u')
        from=$(epoch_local $(( today - (dow - 1) * 86400 )) '%Y-%m-%d')
        to=$(epoch_local $(( today + (7 - dow) * 86400 )) '%Y-%m-%d')
        shift ;;
      --month)
        from=$(date '+%Y-%m-01')
        to=$(epoch_local "$(date '+%s')" '%Y-%m-%d'); shift ;;
      --json)     json=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) day="$1"; shift ;;
    esac
  done

  if [ -z "$from" ]; then
    from=$(resolve_date "${day:-today}")
    to="$from"
  fi
  [ -n "$to" ] || to="$from"

  local since_e until_e since_iso until_iso
  since_e=$(to_epoch "$from 00:00:00")
  until_e=$(( $(to_epoch "$to 00:00:00") + 86400 ))
  since_iso=$(epoch_utc "$since_e" '%Y-%m-%dT%H:%M:%SZ')
  until_iso=$(epoch_utc "$until_e" '%Y-%m-%dT%H:%M:%SZ')

  local page=1 pages=1 all='[]' resp
  while [ "$page" -le "$pages" ]; do
    resp=$(api GET "/v2/entries?time_since=$(urlenc "$since_iso")&time_until=$(urlenc "$until_iso")&page=$page")
    pages=$(printf '%s' "$resp" | jq -r '.paging.count_pages // 1')
    all=$(jq -nc --argjson a "$all" --argjson r "$(printf '%s' "$resp" | jq -c '.entries // []')" '$a + $r')
    page=$(( page + 1 ))
    [ "$page" -gt 50 ] && break
  done

  if [ "$json" = 1 ]; then printf '%s\n' "$all" | jq .; return 0; fi

  local count
  count=$(printf '%s' "$all" | jq 'length')
  if [ "$count" = 0 ]; then
    info "No entries between $from and $to."
    return 0
  fi

  printf '%s%s → %s%s\n\n' "$C_BLD" "$from" "$to" "$C_OFF"

  local prev_day='' total=0 what until_txt
  while IFS="$SEP" read -r eid ts tu txt cust proj svc; do
    local s_e u_e mins d
    s_e=$(iso_to_epoch "$ts")
    if [ -n "$tu" ]; then
      u_e=$(iso_to_epoch "$tu"); until_txt=$(epoch_local "$u_e" '%H:%M')
    else
      u_e=$(date '+%s'); until_txt='now'
    fi
    mins=$(( (u_e - s_e) / 60 ))
    total=$(( total + mins ))
    d=$(epoch_local "$s_e" '%a %Y-%m-%d')
    if [ "$d" != "$prev_day" ]; then
      if [ -n "$prev_day" ]; then printf '\n'; fi
      printf '%s%s%s\n' "$C_BLD" "$d" "$C_OFF"
      prev_day="$d"
    fi
    what="$cust${proj:+ / $proj}"
    printf '  %s–%s  %5s  %-32.32s %-14.14s %s%s%s %s#%s%s\n' \
      "$(epoch_local "$s_e" '%H:%M')" "$until_txt" \
      "$(awk -v m="$mins" 'BEGIN{printf "%.2f", m/60}')" \
      "$what" "$svc" "$C_DIM" "${txt:-}" "$C_OFF" "$C_DIM" "$eid" "$C_OFF"
  done < <(printf '%s' "$all" | jq -r --arg sep "$SEP" '
    sort_by(.time_since)[] |
    [ (.id|tostring), .time_since, (.time_until // ""),
      ((.text // "")|gsub("[\n\r\t]";" ")),
      (.customers_name // ""), (.projects_name // ""), (.services_name // "") ]
    | join($sep)')

  printf '\n%sTotal: %s over %s %s%s\n' "$C_BLD" "$(fmt_hours "$total")" "$count" \
    "$(plural "$count" entry entries)" "$C_OFF"
}

# ------------------------------------------------------------------- ids ----

cmd_ids() {
  local kind="${1:-all}"; shift || true
  local customer='' search=''
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--customer) customer="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option for ids: $1" ;;
      *) search="$1"; shift ;;
    esac
  done

  # `ids` on its own prints the three lists you need for the config
  if [ "$kind" = all ]; then
    local k
    for k in customers projects services; do
      printf '%s%s%s\n' "$C_BLD" "$k" "$C_OFF"
      ids_one "$k" "$customer" "$search" | sed 's/^/  /'
      printf '\n'
    done
    return 0
  fi
  ids_one "$kind" "$customer" "$search"
}

ids_one() { # kind customer_filter search
  local kind="$1" customer="$2" search="$3" rows=''
  case "$kind" in
    customers)
      rows=$(api GET /v2/customers | jq -r --arg s "$SEP" --arg q "$search" '
        ["ID","CUSTOMER"], ((.customers // [])[]
        | select(.active != false)
        | select($q == "" or ((.name // "") | ascii_downcase | contains($q | ascii_downcase)))
        | [(.id|tostring), (.name // "")]) | join($s)') ;;
    projects)
      local p='/v2/projects'
      if [ -n "$customer" ]; then p="$p?filter%5Bcustomers_id%5D=$customer"; fi
      rows=$(api GET "$p" | jq -r --arg s "$SEP" --arg q "$search" '
        ["ID","CUSTOMER","PROJECT"], ((.projects // [])[]
        | select(.active != false)
        | select($q == "" or (((.name // "") + " " + (.customers_name // "")) | ascii_downcase | contains($q | ascii_downcase)))
        | [(.id|tostring), (.customers_name // ""), (.name // "")]) | join($s)') ;;
    services)
      rows=$(api GET /v2/services | jq -r --arg s "$SEP" --arg q "$search" '
        ["ID","SERVICE"], ((.services // [])[]
        | select(.active != false)
        | select($q == "" or ((.name // "") | ascii_downcase | contains($q | ascii_downcase)))
        | [(.id|tostring), (.name // "")]) | join($s)') ;;
    users)
      rows=$(api_first GET /v3/users /v2/users /users | jq -r --arg s "$SEP" --arg q "$search" '
        ["ID","NAME","EMAIL"], ((.users // [])[]
        | select($q == "" or (((.name // "") + " " + (.email // "")) | ascii_downcase | contains($q | ascii_downcase)))
        | [(.id|tostring), (.name // ""), (.email // "")]) | join($s)') ;;
    *) die "unknown kind '$kind' (customers, projects, services, users — or nothing for all three)" ;;
  esac

  # a lone header row means the filter matched nothing
  if [ "$(printf '%s\n' "$rows" | wc -l)" -le 1 ]; then
    printf '%s(none%s)%s\n' "$C_DIM" "${search:+ matching \"$search\"}" "$C_OFF"
    return 0
  fi
  printf '%s\n' "$rows" | tabulate
}

# ----------------------------------------------------------------- guard ----

cmd_guard() {
  local day='' since_e='' until_e=''
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--date) day="${2:-}"; shift 2 ;;
      --types)
        local t
        for t in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
          printf '%2s  %s\n' "$t" "$(absence_type_name "$t")"
        done
        return 0 ;;
      -h|--help) usage; exit 0 ;;
      *) day="$1"; shift ;;
    esac
  done
  day=$(resolve_date "${day:-today}")
  since_e=$(to_epoch "$day 09:00:00")
  until_e=$(to_epoch "$day 17:00:00")

  printf '%s%s (%s)%s\n\n' "$C_BLD" "$day" "$(epoch_local "$since_e" '%A')" "$C_OFF"

  local ok=1 name
  for name in workday holiday absence existing_entries; do
    GUARD_REASON=''
    local label enabled='on'
    case "$name" in
      workday)          label='working day     '; [ "$CLOCKODO_SKIP_NON_WORKDAYS" = 1 ] || enabled='off' ;;
      holiday)          label='holiday         '; [ "$CLOCKODO_SKIP_HOLIDAYS" = 1 ] || enabled='off' ;;
      absence)          label='absence         '; [ "$CLOCKODO_SKIP_ABSENCES" = 1 ] || enabled='off' ;;
      existing_entries) label='existing entries'; [ "$CLOCKODO_ON_EXISTING_ENTRIES" != off ] || enabled='off' ;;
    esac
    if [ "$enabled" = off ]; then
      printf '  %s·%s %s  %sdisabled%s\n' "$C_DIM" "$C_OFF" "$label" "$C_DIM" "$C_OFF"
      continue
    fi
    if "guard_$name" "$day" "$since_e" "$until_e"; then
      printf '  %s✓%s %s  clear\n' "$C_GRN" "$C_OFF" "$label"
    else
      printf '  %s✗%s %s  %s\n' "$C_RED" "$C_OFF" "$label" "$GUARD_REASON"
      ok=0
    fi
  done

  printf '\n'
  if [ "$ok" = 1 ]; then
    printf '%s✓%s a `log` for %s would be recorded\n' "$C_GRN" "$C_OFF" "$day"
  else
    printf '%s—%s a `log` for %s would be skipped (use --force to override)\n' "$C_YEL" "$C_OFF" "$day"
  fi
}

# ---------------------------------------------------------------- delete ----

cmd_delete() {
  local id="${1:-}"
  [ -n "$id" ] || die "usage: clockodo.sh delete <entry-id>"
  case "$id" in *[!0-9]*) die "entry ID must be numeric" ;; esac
  api DELETE "/v2/entries/$id" >/dev/null
  printf '%s✓%s deleted entry %s\n' "$C_GRN" "$C_OFF" "$id"
}

# ----------------------------------------------------------------- check ----

cmd_check() {
  require_credentials
  printf 'config      %s%s\n' "$CONFIG_FILE" "$([ -f "$CONFIG_FILE" ] || printf ' (missing)')"
  printf 'email       %s\n' "$CLOCKODO_EMAIL"
  printf 'api key     %s…%s\n' "${CLOCKODO_API_KEY:0:4}" "${CLOCKODO_API_KEY: -2}"
  printf 'time zone   %s\n' "${TZ:-$(date '+%Z')}"
  printf 'customer    %s\n' "${CLOCKODO_CUSTOMERS_ID:-(unset)}"
  printf 'project     %s\n' "${CLOCKODO_PROJECTS_ID:-(unset)}"
  printf 'service     %s\n' "${CLOCKODO_SERVICES_ID:-(unset)}"
  printf 'billable    %s\n' "$CLOCKODO_BILLABLE"
  local names
  names=$(set | sed -n 's/^ALIAS_\([A-Za-z0-9_]*\)_\(CUSTOMERS_ID\|PROJECTS_ID\|SERVICES_ID\|BILLABLE\|TEXT\)=.*/\1/p' | sort -u | tr '\n' ' ')
  printf 'aliases     %s\n' "${names:-(none)}"
  printf '\n'
  printf 'guards      workdays %s (%s)\n' \
    "$([ "$CLOCKODO_SKIP_NON_WORKDAYS" = 1 ] && printf on || printf off)" "$CLOCKODO_WORKDAYS"
  printf '            holidays %s\n' "$([ "$CLOCKODO_SKIP_HOLIDAYS" = 1 ] && printf on || printf off)"
  printf '            absences %s (states %s, ignoring types %s)\n' \
    "$([ "$CLOCKODO_SKIP_ABSENCES" = 1 ] && printf on || printf off)" \
    "$CLOCKODO_ABSENCE_STATUSES" "$CLOCKODO_ABSENCE_IGNORE_TYPES"
  printf '            existing entries: %s\n' "$CLOCKODO_ON_EXISTING_ENTRIES"
  printf '\n'
  api GET /v2/customers >/dev/null
  printf '%s✓%s credentials accepted by %s\n' "$C_GRN" "$C_OFF" "$API_BASE"
  resolve_user
  printf '%s✓%s you are user %s%s\n' "$C_GRN" "$C_OFF" "$USER_ID" \
    "${USER_NONBUSINESS_GROUP:+ (nonbusiness group $USER_NONBUSINESS_GROUP)}"
}

# ------------------------------------------------------------------ main ----

# Everything an API-touching command needs before it starts: a config file
# (written from the template on a first run) and usable credentials.
setup() {
  ensure_config
  load_config
  require_credentials
}

# A scheduled run and a manual one must not both write the same entry.
# mkdir is the portable atomic test-and-set; macOS has no flock.
LOCK_DIR=''
take_lock() {
  LOCK_DIR="${TMPDIR:-/tmp}/clockodo-$(id -u).lock"
  local waited=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    # a lock older than 5 minutes is a crashed run, not a live one
    if [ -d "$LOCK_DIR" ] && [ -z "$(find "$LOCK_DIR" -maxdepth 0 -mmin -5 2>/dev/null)" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      continue
    fi
    waited=$(( waited + 2 ))
    [ "$waited" -le 30 ] || die "another clockodo.sh is running (lock: $LOCK_DIR)"
    sleep 2
  done
  trap 'rm -rf "$LOCK_DIR" 2>/dev/null; exit 1' TERM INT
  trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
}

main() {
  command -v curl >/dev/null || die "curl is required"
  command -v jq   >/dev/null || die "jq is required (brew install jq / apt install jq)"

  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --config)  CONFIG_FILE="${2:-}"; shift 2 ;;
      -v|--verbose) VERBOSE=1; shift ;;
      --refresh|--no-cache) NO_CACHE=1; shift ;;
      --log)     LOG_FILE="${2:-}"; shift 2 ;;
      --version) printf 'clockodo.sh %s\n' "$VERSION"; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}

  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    init)              cmd_init ;;
    log|add)           setup; take_lock; cmd_log "$@" ;;
    list|ls|entries)   setup; cmd_list "$@" ;;
    ids|id)            setup; cmd_ids "$@" ;;
    guard|guards|why)  setup; cmd_guard "$@" ;;
    delete|rm)         setup; cmd_delete "$@" ;;
    check|whoami)      setup; cmd_check "$@" ;;
    cache-clear)       cmd_cache_clear ;;
    help|-h|--help)    usage ;;
    *) die "unknown command '$cmd' — run: clockodo.sh help" ;;
  esac
}

main "$@"
