#!/usr/bin/env bash
# kimi-tmux-status.sh — drive per-window agent status icons in the tmux status bar
# from Kimi Code hooks (see [[hooks]] in ~/.config/kimi-code/config.toml).
#
# State is kept in window user options, rendered by window-status-format:
#   @kimi_run   counter, turns running (orange ●)
#   @kimi_done  space-separated session ids finished but not yet reviewed (green ●);
#               @kimi_donec mirrors the count for rendering. Cleared per session — checking one agent never dismisses another's:
#               nvim-hosted agents via agents.lua (`seen` on buffer focus),
#               CLI-in-pane agents via after-select-window (`seen-window`),
#               any agent when it starts a new interactive turn or exits
#   @kimi_bg    counter, background tasks / cron turns (blue ●); reconciled against
#               the session's task files at every turn end, because stopped tasks
#               emit no Notification and would leak otherwise
#
# Hooks pass a JSON payload on stdin ({session_id, origin_kind, ...}); the pane is
# identified via $TMUX_PANE inherited from the CLI. Always exits 0 (fail-open).

set -u

# seen-window is invoked from a tmux set-hook (run-shell): no pane env, no payload
case "${1:-}" in
seen-window) ;;
*)
	[ -n "${TMUX_PANE:-}" ] || exit 0
	;;
esac

STATE_DIR=/tmp/kimi-tmux-status
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# seen/clear/seen-window don't read stdin (would block on a terminal)
case "${1:-}" in
seen | clear | seen-window) payload="" ;;
*) payload="$(cat 2>/dev/null || true)" ;;
esac

# extract a flat string field from the payload (no jq dependency)
json_str() {
	printf '%s' "$payload" |
		sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

session_id=$(json_str session_id)
# fall back to a per-pane key so turn-begin/turn-end still pair up deterministically
[ -n "$session_id" ] || session_id="pane-${TMUX_PANE:-unknown}"

KIMI_HOME=${KIMI_CODE_HOME:-$HOME/.config/kimi-code}

refresh_status() {
	tmux list-clients -F '#{client_name}' 2>/dev/null |
		while read -r c; do tmux refresh-client -S -t "$c" 2>/dev/null; done
	return 0
}

# window id (@N) of the pane this hook fired from; stable across renumbering
pane_window() {
	tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null
}

# the pane runs a kimi CLI directly (not nvim hosting agents in terminal buffers)
pane_is_kimi() {
	tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null |
		grep -qxE 'kimi(-code)?'
}

# the user is watching this exact session: kimi runs directly in the pane and its
# window is active in an attached session
session_visible() {
	local pane=$1 active
	[ -n "$pane" ] && pane_is_kimi "$pane" || return 1
	active=$(tmux display-message -p -t "$pane" \
		'#{?#{&&:#{window_active},#{session_attached}},1,0}' 2>/dev/null)
	[ "$active" = "1" ]
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

# mark a session as "finished, needs review" on its window; a <sid>.done file
# records "window_id pane_id" so done_del/seen-window work without hook context
done_add() { # <session_id> <window_id>
	local sid=$1 win=$2 cur new
	[ -n "$win" ] && [ -n "$sid" ] || return 0
	# no green needed while the user is already watching this CLI-in-pane session
	session_visible "${TMUX_PANE:-}" && return 0
	(
		flock -w 5 9 || exit 0
		cur=$(tmux show-option -wqv -t "$win" @kimi_done 2>/dev/null)
		case " $cur " in *" $sid "*) exit 0 ;; esac
		new="${cur:+$cur }$sid"
		set -- $new
		tmux set-option -wq -t "$win" @kimi_done "$new" 2>/dev/null
		tmux set-option -wq -t "$win" @kimi_donec "$#" 2>/dev/null
		printf '%s %s\n' "$win" "${TMUX_PANE:-}" >"$STATE_DIR/$sid.done"
	) 9>"$STATE_DIR/.lock.$win"
	refresh_status
}

# clear one session's green, leaving other sessions' greens on the window intact
done_del() { # <session_id>
	local sid=$1 win cur new
	[ -n "$sid" ] && [ -f "$STATE_DIR/$sid.done" ] || return 0
	read -r win _ <"$STATE_DIR/$sid.done"
	rm -f "$STATE_DIR/$sid.done"
	[ -n "$win" ] || return 0
	(
		flock -w 5 9 || exit 0
		cur=$(tmux show-option -wqv -t "$win" @kimi_done 2>/dev/null)
		new=$(printf '%s' " $cur " | sed "s/ $sid / /g; s/^ *//; s/ *$//")
		if [ -n "$new" ]; then
			set -- $new
			tmux set-option -wq -t "$win" @kimi_done "$new" 2>/dev/null
			tmux set-option -wq -t "$win" @kimi_donec "$#" 2>/dev/null
		else
			tmux set-option -wqu -t "$win" @kimi_done 2>/dev/null
			tmux set-option -wqu -t "$win" @kimi_donec 2>/dev/null
		fi
	) 9>"$STATE_DIR/.lock.$win"
	refresh_status
}

# true-up the session's blue counter against its task files: stopped tasks emit
# no Notification (terminalNotificationSuppressed), so bg-end never fires for them
bg_reconcile() { # <session_id> <window_id>
	local sid=$1 win=$2 dir n have bwin
	case "$sid" in pane-*) return 0 ;; esac
	dir=$(sed -n '/"sessionId": *"'"$sid"'"/{s/.*"sessionDir": *"\([^"]*\)".*/\1/p;q}' \
		"$KIMI_HOME/session_index.jsonl" 2>/dev/null)
	[ -n "$dir" ] && [ -d "$dir" ] || return 0
	n=$(grep -l '"status":"running"' "$dir"/agents/*/tasks/bash-*.json 2>/dev/null | wc -l)
	(
		flock -w 5 9 || exit 0
		have=0
		if [ -f "$STATE_DIR/$sid.bg" ]; then
			read -r have bwin <"$STATE_DIR/$sid.bg"
			win=$bwin
		fi
		[ -n "$win" ] || exit 0
		[ "$n" -eq "$have" ] && exit 0
		if [ "$n" -gt 0 ]; then
			printf '%s %s\n' "$n" "$win" >"$STATE_DIR/$sid.bg"
		else
			rm -f "$STATE_DIR/$sid.bg"
		fi
		adjust @kimi_bg "$((n - have))" "$win"
	) 9>"$STATE_DIR/.lock.bg"
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
	# an interactive turn means the user is engaging this session right now;
	# cron/system turns must not clear the green
	[ "$kind" = run ] && done_del "$session_id"
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
	[ "$outcome" = interrupt ] || done_add "$session_id" "$win"
	bg_reconcile "$session_id" "$win"
	;;
# Background-task accounting pairs TaskStarted with terminal Notifications, and
# tracks per-session outstanding counts ("count window_id" in <session_id>.bg) so
# session-end can sweep tasks that end without any notification (e.g. TaskStop,
# verified: stopped tasks emit none) or die with the session. One global lock
# keeps the window counter and the session file consistent.
bg-begin)
	win=$(pane_window)
	[ -n "$win" ] || exit 0
	(
		flock -w 5 9 || exit 0
		n=0
		[ -f "$STATE_DIR/$session_id.bg" ] && read -r n _ <"$STATE_DIR/$session_id.bg"
		printf '%s %s\n' "$((n + 1))" "$win" >"$STATE_DIR/$session_id.bg"
	) 9>"$STATE_DIR/.lock.bg"
	adjust @kimi_bg 1 "$win"
	;;
bg-end)
	win=$(pane_window)
	(
		flock -w 5 9 || exit 0
		if [ -f "$STATE_DIR/$session_id.bg" ]; then
			read -r n win <"$STATE_DIR/$session_id.bg"
			n=$((n - 1))
			if [ "$n" -le 0 ]; then
				rm -f "$STATE_DIR/$session_id.bg"
			else
				printf '%s %s\n' "$n" "$win" >"$STATE_DIR/$session_id.bg"
			fi
		fi
	) 9>"$STATE_DIR/.lock.bg"
	adjust @kimi_bg -1 "$win"
	;;
session-end)
	if [ -f "$STATE_DIR/$session_id" ]; then
		read -r kind win <"$STATE_DIR/$session_id"
		rm -f "$STATE_DIR/$session_id"
		adjust "$(opt_for_kind "$kind")" -1 "$win"
	fi
	if [ -f "$STATE_DIR/$session_id.bg" ]; then
		read -r n win <"$STATE_DIR/$session_id.bg"
		rm -f "$STATE_DIR/$session_id.bg"
		adjust @kimi_bg -"$n" "$win"
	fi
	done_del "$session_id"
	;;
# called by agents.lua when the agent's terminal buffer is focused
seen)
	done_del "${2:-$session_id}"
	;;
# called by tmux after-select-window with the window id: viewing a window checks
# any agent that runs directly in one of its panes; nvim-hosted agents keep their
# green until their own buffer is focused (agents.lua `seen`)
seen-window)
	win=${2:-}
	[ -n "$win" ] || exit 0
	cur=$(tmux show-option -wqv -t "$win" @kimi_done 2>/dev/null)
	[ -n "$cur" ] || exit 0
	for sid in $cur; do
		[ -f "$STATE_DIR/$sid.done" ] || continue
		read -r _ spane <"$STATE_DIR/$sid.done"
		[ -n "$spane" ] && pane_is_kimi "$spane" && done_del "$sid"
	done
	;;
# manual reset for a window whose icons got stuck: run from the affected pane
clear)
	win=$(pane_window)
	[ -n "$win" ] || exit 0
	tmux set-option -wqu -t "$win" @kimi_run 2>/dev/null
	tmux set-option -wqu -t "$win" @kimi_done 2>/dev/null
	tmux set-option -wqu -t "$win" @kimi_donec 2>/dev/null
	tmux set-option -wqu -t "$win" @kimi_bg 2>/dev/null
	for f in "$STATE_DIR"/*.done; do
		[ -f "$f" ] || continue
		read -r fwin _ <"$f"
		[ "$fwin" = "$win" ] && rm -f "$f"
	done
	refresh_status
	;;
esac
exit 0
