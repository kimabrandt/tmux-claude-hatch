#!/usr/bin/env bash
# Emit one picker row per running Claude that lives in a tmux pane.
#
# Claude self-reports its status: each session writes its own state to disk and a
# supervisor daemon aggregates it, which `claude agents --json` publishes. So this
# needs no Claude Code hooks, and no `pane_current_command` scan — on macOS a pane
# reports its parent shell there, never the `claude` child running inside it.
#
# Identity is the Claude process, not the tmux session. Joining pid -> tty -> pane
# is what lets several Claudes in one project (same cwd, same session, different
# windows) each get a row of their own.
#
#   Row: key \t pane_id \t pid \t kind \t icon \t age \t loc \t path
#   key/pane_id/pid/kind are hidden from the display via fzf's --with-nth.
#
# `key` is the numeric sort key, and what @claude_sort selects:
#   status  (default)  status rank — whatever needs you floats up
#   recent             seconds since last activity — most recently used first
#
# The key counts seconds while the age column reads no finer than minutes: a
# session started ten seconds ago and the one you left a minute ago are both
# "now", and ordering those by the displayed minute leaves the tie to sort's
# last-resort line comparison — i.e. to pane ids.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

agents="$($(get_tmux_option @claude_command 'claude') agents --json 2>/dev/null)" || exit 0
rows="$(printf '%s' "$agents" |
  jq -r '.[] | select(.kind == "interactive")
         | [.pid, .status, .sessionId, .cwd, .startedAt, (.profile // "")] | @tsv' 2>/dev/null)"
[ -n "$rows" ] || exit 0

# Resolved out here because awk cannot read a transcript's entries itself. The
# profile rides along because a session's transcript lives under the config dir
# of the profile it belongs to, which is not necessarily the picker's own.
seen="$(printf '%s\n' "$rows" | cut -f3,6 | while IFS=$'\t' read -r sid profile; do
  printf 'M\t%s\t%s\n' "$sid" "$(claude_last_activity "$sid" "$profile")"
done)"

# Three tagged streams into one awk: pid->tty, tty->pane, session->last-activity.
# Total cost is 3 subprocesses regardless of how many sessions or panes exist.
{
  ps -Ao pid=,tty= 2>/dev/null | awk '{ print "P\t" $1 "\t" $2 }'
  tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
  printf '%s\n' "$seen"
  printf '%s\n' "$rows" | sed $'s/^/A\t/'
} | awk -F'\t' -v now="$(date +%s)" -v home="$HOME" \
  -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" \
  -v sort_by="$(get_tmux_option @claude_sort 'status')" '
  BEGIN { UNKNOWN = 99999999 }   # ~3 years in seconds; no real age reaches it
  # The two largest units, no space: now, 59m, 1h06m, 2d03h. The second unit gets
  # two digits so the column lines up. At most 6 characters below 100 days.
  function fmt_age(s,   m, h, d) {
    m = int(s / 60); h = int(m / 60); d = int(h / 24)
    if (m == 0) return "now"
    if (h == 0) return m "m"
    if (d == 0) return sprintf("%dh%02dm", h, m % 60)
    return sprintf("%dd%02dh", d, h % 24)
  }
  $1 == "P" { tty_of[$2] = $3; next }
  $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; loc[$2] = $5; next }
  $1 == "M" { seen_at[$2] = $3; next }
  $1 == "A" {
    tty = tty_of[$2]
    if (tty == "" || !(tty in pane)) next   # this Claude is not running inside tmux

    if      ($3 == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
    else if ($3 == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
    else if ($3 == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
    else                      { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - unrecognised status

    # Seconds since last activity, or UNKNOWN when the transcript could not be
    # read. This is the only thing the age column is ever allowed to show.
    secs = (seen_at[$4] != "") ? now - seen_at[$4] : UNKNOWN
    if (secs != UNKNOWN) {
      if (secs < 0) secs = 0                     # activity in the future: clock skew
      if (secs >= UNKNOWN) secs = UNKNOWN - 1
    }
    age = (secs != UNKNOWN) ? fmt_age(secs) : "-"
    kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"

    path = $5
    if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

    # startedAt is a birth time, not a use time: it grows for as long as the
    # process lives and never resets when the agent answers you, so rendering it
    # in the age column reads as a stopwatch stuck mid-count. It can still place
    # a row, though. In recent mode the age *is* the order, so an agent with no
    # readable activity is positioned by when it started — and still displays
    # '-', because that position is a guess, not a measurement. In status mode
    # the age is only a tie-break, so an unknown one leads its status group.
    if (secs != UNKNOWN)
      agekey = secs
    else if (sort_by == "recent" && $6 > 0) {
      agekey = int(now - $6 / 1000)
      if (agekey < 0) agekey = 0
      if (agekey >= UNKNOWN) agekey = UNKNOWN - 1
    }
    else
      agekey = (sort_by == "recent") ? UNKNOWN : -1

    # One composite key: age breaks ties within a status rank, and carries the
    # whole order in recent mode.
    key = (sort_by == "recent") ? agekey : rank * (UNKNOWN + 1) + agekey

    printf "%s\t%s\t%s\t%s\t%s\t%6s\t%s\t%s\n",
      key, pane[tty], $2, kind, icon, age, loc[tty], path
  }
' | LC_ALL=C sort -t$'\t' -k1,1n -k7,7
# key asc; it already folds in the age. The location breaks a genuine tie (two
# agents idle the same second) so the row order stays stable across refreshes
# rather than falling to sort's last-resort whole-line comparison.
