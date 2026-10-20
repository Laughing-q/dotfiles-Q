#!/usr/bin/env bash
# kimi-tmux-status.sh — drive per-window agent status icons in the tmux status bar
# from Kimi Code hooks (see [[hooks]] in ~/.config/kimi-code/config.toml).
#
# State is kept in window user options, rendered by window-status-format:
#   @kimi_run   counter, turns running (orange ●)
#   @kimi_done  flag, turn finished and window not viewed since (green ●)
#   @kimi_bg    counter, background tasks / cron turns (blue ●)
#
# Hooks pass a JSON payload on stdin ({session_id, origin_kind, ...}); the pane is
# identified via $TMUX_PANE inherited from the CLI. Always exits 0 (fail-open).

set -u

[ -n "${TMUX_PANE:-}" ] || exit 0

STATE_DIR=/tmp/kimi-tmux-status
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null || true)"

# extract a flat string field from the payload (no jq dependency)
json_str() {
	printf '%s' "$payload" |
		sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

session_id=$(json_str session_id)
# fall back to a per-pane key so turn-begin/turn-end still pair up deterministically
[ -n "$session_id" ] || session_id="pane-$TMUX_PANE"

refresh_status() {
	tmux list-clients -F '#{client_name}' 2>/dev/null |
		while read -r c; do tmux refresh-client -S -t "$c" 2>/dev/null; done
	return 0
}

# window id (@N) of the pane this hook fired from; stable across renumbering
pane_window() {
	tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null
}

# adjust <@option> <delta> <window_id>; counter is unset when it reaches 0
adjust() {
	local opt=$1 delta=$2 win=$3 cur new
	[ -n "$win" ] || return 0
	(
		flock -w 5 9 || exit 0
		cur=$(tmux show-option -wqv -t "$win" "$opt" 2>/dev/null)
		cur=${cur:-0}
		new=$((cur + delta))
		if [ "$new" -le 0 ]; then
			tmux set-option -wqu -t "$win" "$opt" 2>/dev/null
		else
			tmux set-option -wq -t "$win" "$opt" "$new" 2>/dev/null
		fi
	) 9>"$STATE_DIR/.lock.$win"
	refresh_status
}

# flag a window as "finished, needs review" unless the user is already viewing it
mark_done() {
	local win=$1 active
	[ -n "$win" ] || return 0
	active=$(tmux display-message -p -t "$win" \
		'#{?#{&&:#{window_active},#{session_attached}},1,0}' 2>/dev/null)
	[ "$active" = "1" ] && return 0
	tmux set-option -wq -t "$win" @kimi_done 1 2>/dev/null
	refresh_status
}

opt_for_kind() { # run|bg -> window option name
	[ "$1" = "bg" ] && printf '@kimi_bg' || printf '@kimi_run'
}

case "${1:-}" in
turn-begin)
	win=$(pane_window)
	[ -n "$win" ] || exit 0
	origin=$(json_str origin_kind)
	kind=run
	# cron-fired turns report origin_kind=cron_job; system covers other
	# non-interactive triggers (verified empirically, docs list neither)
	case "$origin" in system_trigger | cron_job) kind=bg ;; esac
	printf '%s %s\n' "$kind" "$win" >"$STATE_DIR/$session_id"
	adjust "$(opt_for_kind "$kind")" 1 "$win"
	;;
turn-end)
	outcome=${2:-ok}
	kind=run
	win=$(pane_window)
	if [ -f "$STATE_DIR/$session_id" ]; then
		read -r kind win <"$STATE_DIR/$session_id"
		rm -f "$STATE_DIR/$session_id"
	fi
	adjust "$(opt_for_kind "$kind")" -1 "$win"
	[ "$outcome" = interrupt ] || mark_done "$win"
	;;
bg-begin)
	adjust @kimi_bg 1 "$(pane_window)"
	;;
bg-end)
	adjust @kimi_bg -1 "$(pane_window)"
	;;
session-end)
	if [ -f "$STATE_DIR/$session_id" ]; then
		read -r kind win <"$STATE_DIR/$session_id"
		rm -f "$STATE_DIR/$session_id"
		adjust "$(opt_for_kind "$kind")" -1 "$win"
	fi
	;;
esac
exit 0
