#!/usr/bin/env bash
# Interactive picker for running Claude agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows and refresh the cache (used by fzf's
#                       async initial load and by the ctrl-x reload).
#   picker.sh --copy <text>
#                       copy <text> to the clipboard (used by ctrl-y).
#   picker.sh --preview <pane>
#                       capture that pane for fzf's preview window.
#
# Rows come from agents.sh, which pairs each running Claude with the tmux pane it
# occupies. Two kinds of row jump differently:
#   dedicated  a Claude in a `claude-*` session this plugin launched — resumed in
#              the popup, over the window it was launched from.
#   loose      a Claude running in any other pane — focused in place.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

cache="${TMPDIR:-/tmp}/tmux-claude-agents-$(id -u).cache"

if [ "${1:-}" = '--list' ]; then
  tmp="$cache.$$"
  "$DIR/agents.sh" >"$tmp" 2>/dev/null
  mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
  cat "$cache" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = '--copy' ]; then
  copy_to_clipboard "${2:-}" &&
    tmux display-message "tmux-claude-hatch: copied ${2:-}"
  exit 0
fi

# capture-pane returns the whole pane, and Claude pads the gap between the last
# transcript line and its input box out to the bottom of the pane. That padding
# is interior — the box follows it — so trimming only the end of the capture
# leaves it in place, and the preview window, which follows the last line, parks
# in it and reads as empty. Collapse the padding instead so `follow` lands on
# real output.
#
# Without -S the capture stops at the top of the screen, leaving nothing to
# scroll back into; -S -<n> prepends n lines of scrollback. @claude_preview_lines
# sets n; 0 keeps the capture to the visible screen.
if [ "${1:-}" = '--preview' ]; then
  preview_lines="$(get_tmux_option @claude_preview_lines '1000')"
  capture=(tmux capture-pane -ept "${2:-}")
  [ "$preview_lines" -gt 0 ] 2>/dev/null && capture+=(-S "-$preview_lines")
  "${capture[@]}" 2>/dev/null |
    awk -v esc="$(printf '\033')" '
      {
        bare = $0
        # Attributes are not content. Built as a dynamic regex because a literal
        # \033 in a regex is not portable across awks.
        gsub(esc "\\[[0-9;?]*[ -/]*[@-~]", "", bare)
        # Hold a run of blank lines until the next real line says what it was.
        # Keep the first of the run: it carries the attribute reset that closed
        # the line above it.
        if (bare !~ /[^ \t]/) {
          if (held++ == 0) pad = $0
          next
        }
        # Any run longer than a line is layout, not content, so one blank stands
        # in for the whole run. A run that opens the capture separates nothing,
        # and a run still held at EOF is the trailing padding the follow view
        # would park in — both go unprinted.
        if (seen && held) print pad
        held = 0
        seen = 1
        print
      }
    '
  exit 0
fi

for tool in fzf jq "$(get_tmux_option @claude_command 'claude')"; do
  command -v "$tool" >/dev/null 2>&1 || {
    tmux display-message "tmux-claude-hatch: $tool is required for the picker"
    exit 0
  }
done

self="$DIR/picker.sh"
export FZF_DEFAULT_OPTS=''
export CLAUDE_PICKER="$self"

# Arbitrary user fzf options (e.g. custom --bind or --preview-window)
extra_opts=()
fzf_options="$(get_tmux_option @claude_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

# Put the cursor on the best match while typing. fzf's --track re-pins whatever
# item was current after *every* result update, including the one a keystroke
# causes, so the cursor ends up next to the best match rather than on it. No
# path here wants that pinning: the query should follow the match, and the
# cached-to-fresh swap below should land on the top row of the new order. So
# --track is gone, and `change:first` states the default outright.
cursor_opts=(--bind='change:first')

# Load the session list asynchronously
list_cmd=("$self" --list)
sync_opts=()
now=$(date +%s)
mtime=$(file_mtime "$cache")
if [ -s "$cache" ] && [ -n "$mtime" ] && [ $((now - mtime)) -lt 3600 ]; then
  list_cmd=(cat "$cache")
  sync_opts=(--bind "load:unbind(load)+reload-sync($self --list)")
fi

# ctrl-x kills the Claude process itself: a dedicated session dies with its last
# window, while a loose pane keeps the shell that hosted it. The reload waits a
# beat so the supervisor has dropped the agent from `claude agents --json`.
# ctrl-y copies the agent's location (session:window.pane, e.g. claude-88074b0e:0.0)
# and closes the picker.
#
# The preview is a snapshot taken per selection, shown from the bottom
# (`follow`). ctrl-f re-captures the pane and returns to the end of it, so it
# doubles as a refresh. shift-up/shift-down already scroll it by a line; the
# half-page keys are the addition. The mouse wheel scrolls it too, when tmux
# has `mouse on`.
sel=$("${list_cmd[@]}" | fzf --ansi --delimiter='\t' --with-nth=5,6,7,8 \
  --reverse --cycle \
  --header='Claude agents · enter: jump · ctrl-x: kill · ctrl-y: copy · ctrl-u/ctrl-d: scroll preview' \
  --preview="$self --preview {2}" --preview-window='up,70%,follow' \
  --bind="ctrl-x:execute-silent(kill {3})+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-y:execute-silent($self --copy {7})+abort" \
  --bind='ctrl-u:preview-half-page-up,ctrl-d:preview-half-page-down' \
  --bind='ctrl-f:refresh-preview+preview-bottom' \
  ${cursor_opts[@]+"${cursor_opts[@]}"} \
  ${sync_opts[@]+"${sync_opts[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)

parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)

if [ "$kind" = loose ]; then
  # Focus the pane in place on the outer client. This popup closes on its own
  # when the script exits.
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$session" 2>/dev/null
  else
    tmux switch-client -t "$session" 2>/dev/null
  fi
  tmux select-window -t "$pane" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
  exit 0
fi

# Move the parent client to the window the session was launched from (best-effort),
# focus the chosen Claude's own window inside that session, then resume it in THIS
# popup over the top. Falls back to resuming over the current window when
# origin/parent are unknown.
origin=$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)
[ -n "$origin" ] && [ -n "$parent" ] &&
  tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

tmux select-window -t "$pane" 2>/dev/null
tmux select-pane -t "$pane" 2>/dev/null
tmux attach-session -t "$session"
