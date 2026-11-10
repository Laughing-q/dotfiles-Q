#!/usr/bin/env bash
# kimi-tmux-status.sh — per-window agent status icons in the tmux status bar,
# driven by Kimi Code hooks ([[hooks]] in ~/.config/kimi-code/config.toml).
#
# Every event just writes/removes a per-session state file and then RECOMPUTES
# the window's counters from filesystem truth — no delta counters — so crashed
# sessions, killed tasks (they emit no Notification) and missed events all
# self-heal on the next event:
#   $STATE_DIR/<sid>       "run|bg window_id pid" — a turn in flight (bg = cron)
#   $STATE_DIR/<sid>.done  "window_id pane_id"    — turn finished, not reviewed
#   background tasks       — the project's tasks/bash-*.json with status running
#                            (and the recorded pid still alive)
#
# Window options rendered by window-status-format (one ● per unit, capped at 3+):
#   @kimi_run  turns running (orange)      @kimi_bg  background/cron (blue)
#   @kimi_done / @kimi_donec  finished-unreviewed session ids + count (green)
#
# Green clears per session only: nvim-hosted agents when their buffer is focused
# (agents.lua calls `seen`, and also auto-clears when a turn finishes in the
# buffer being viewed), CLI-in-pane agents on window select (`seen-window` from
# after-select-window), any agent on its next interactive turn or exit.
#
# Hooks pass a JSON payload on stdin ({session_id, origin_kind, cwd, ...}); the
# pane is identified via $TMUX_PANE inherited from the CLI. Always exits 0.

set -u

# seen-window runs from a tmux set-hook (run-shell): no pane env, no payload
case "${1:-}" in
seen-window) ;;
*)
	[ -n "${TMUX_PANE:-}" ] || exit 0
	;;
esac

STATE_DIR=/tmp/kimi-tmux-status
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# seen/clear/seen-window/refresh don't read stdin (would block on a terminal)
case "${1:-}" in
seen | clear | seen-window | refresh) payload="" ;;
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
	local cmd
	cmd=$(tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null) || return 1
	case "$cmd" in kimi*) return 0 ;; *) return 1 ;; esac
}

# the user is watching this exact session right now: its pane is in the active
# window of an attached session, and either the pane runs a kimi CLI directly or
# nvim reports the session's buffer as focused (agents.lua publishes the focused
# session id per pane to $STATE_DIR/focused.<pane>)
session_visible() { # <pane> <session_id>
	local pane=$1 sid=$2 active cmd
	[ -n "$pane" ] || return 1
	active=$(tmux display-message -p -t "$pane" \
		'#{?#{&&:#{window_active},#{session_attached}},1,0}' 2>/dev/null)
	[ "$active" = "1" ] || return 1
	cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
	case "$cmd" in
	kimi*) return 0 ;;
	nvim)
		[ -f "$STATE_DIR/focused.$pane" ] || return 1
		[ "$(cat "$STATE_DIR/focused.$pane" 2>/dev/null)" = "$sid" ]
		;;
	*) return 1 ;;
	esac
}

# first kimi* ancestor of this hook process (used to sweep state of
# crashed/killed sessions on later events); comm varies: kimi, kimi-code, kimi-co
kimi_pid() {
	local p=$PPID c
	while [ -n "$p" ] && [ "$p" != 1 ]; do
		c=$(ps -o comm= -p "$p" 2>/dev/null) || break
		case "$c" in kimi*)
			printf '%s\n' "$p"
			return 0
			;;
		esac
		p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
	done
	return 1
}

set_counter() { # <window_id> <@option> <n>: set, or unset when not positive
	[ -n "$1" ] || return 0
	if [ "$3" -gt 0 ] 2>/dev/null; then
		tmux set-option -wq -t "$1" "$2" "$3" 2>/dev/null
	else
		tmux set-option -wqu -t "$1" "$2" 2>/dev/null
	fi
}

# running background tasks across every session of the project (workDir == cwd);
# a task whose recorded pid is dead doesn't count (session died mid-task)
project_tasks() { # <cwd>
	local esc f tp n=0
	[ -n "$1" ] || {
		printf '0\n'
		return 0
	}
	esc=$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')
	while read -r f; do
		tp=$(grep -o '"pid":[0-9][0-9]*' "$f" 2>/dev/null | head -1 | cut -d: -f2)
		if [ -n "$tp" ]; then
			kill -0 "$tp" 2>/dev/null || continue
		fi
		n=$((n + 1))
	done < <(
		while read -r dir; do
			[ -d "$dir" ] && grep -l '"status":"running"' "$dir"/agents/*/tasks/bash-*.json 2>/dev/null
		done < <(sed -n '/"workDir": *"'"$esc"'"/{s/.*"sessionDir": *"\([^"]*\)".*/\1/p}' \
			"$KIMI_HOME/session_index.jsonl" 2>/dev/null)
	)
	printf '%s\n' "$n"
}

# rewrite a window's run/bg counters from truth: live turn state files for that
# window plus the project's running task files; dead sessions' files are swept
recompute() { # <window_id> <cwd>
	local win=$1 cwd=$2 f kind w pid run=0 bg=0 wins
	[ -n "$win" ] || return 0
	(
		flock -w 5 9 || exit 0
		wins=$(tmux list-windows -a -F '#{window_id}' 2>/dev/null)
		for f in "$STATE_DIR"/*; do
			[ -f "$f" ] || continue
			case "$f" in
			*.lock.*) continue ;;
			*.bg) rm -f "$f"; continue ;; # legacy from the delta-counter version
			*.done)
				# sweep greens whose window is gone; the option died with it
				read -r w _ <"$f" 2>/dev/null || continue
				grep -qxF "$w" <<<"$wins" || rm -f "$f"
				continue
				;;
			esac
			read -r kind w pid <"$f" 2>/dev/null || continue
			[ "$w" = "$win" ] || continue
			# pid-less files can't be liveness-checked; keep them (their own
			# turn-end/session-end removes them)
			if [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; then
				case "$kind" in
				run) run=$((run + 1)) ;;
				bg) bg=$((bg + 1)) ;;
				esac
			else
				rm -f "$f"
			fi
		done
		bg=$((bg + $(project_tasks "$cwd")))
		set_counter "$win" @kimi_run "$run"
		set_counter "$win" @kimi_bg "$bg"
	) 9>"$STATE_DIR/.lock.$win"
	refresh_status
}

# mark a session as "finished, needs review" on its window; a <sid>.done file
# records "window_id pane_id" so done_del/seen-window work without hook context
done_add() { # <session_id> <window_id>
	local sid=$1 win=$2 cur new
	[ -n "$win" ] && [ -n "$sid" ] || return 0
	# no green needed while the user is already watching this session
	session_visible "${TMUX_PANE:-}" "$sid" && return 0
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
	printf '%s %s %s\n' "$kind" "$win" "$(kimi_pid)" >"$STATE_DIR/$session_id"
	# an interactive turn means the user is engaging this session right now;
	# cron/system turns must not clear the green
	[ "$kind" = run ] && done_del "$session_id"
	recompute "$win" "$(json_str cwd)"
	;;
turn-end)
	outcome=${2:-ok}
	win=$(pane_window)
	if [ -f "$STATE_DIR/$session_id" ]; then
		read -r _ win _ <"$STATE_DIR/$session_id"
		rm -f "$STATE_DIR/$session_id"
	fi
	rm -f "$STATE_DIR/$session_id.bg" # legacy from the delta-counter version
	[ "$outcome" = interrupt ] || done_add "$session_id" "$win"
	recompute "$win" "$(json_str cwd)"
	;;
# task truth comes from the session task files, so these are recompute triggers
bg-begin | bg-end)
	recompute "$(pane_window)" "$(json_str cwd)"
	;;
session-end)
	rm -f "$STATE_DIR/$session_id" "$STATE_DIR/$session_id.bg"
	done_del "$session_id"
	recompute "$(pane_window)" "$(json_str cwd)"
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
# manual full reset for a window whose icons got stuck: run from the affected pane
clear)
	win=$(pane_window)
	[ -n "$win" ] || exit 0
	tmux set-option -wqu -t "$win" @kimi_run 2>/dev/null
	tmux set-option -wqu -t "$win" @kimi_done 2>/dev/null
	tmux set-option -wqu -t "$win" @kimi_donec 2>/dev/null
	tmux set-option -wqu -t "$win" @kimi_bg 2>/dev/null
	for f in "$STATE_DIR"/*; do
		[ -f "$f" ] || continue
		case "$f" in *.lock.*) continue ;; esac
		read -r fa fb _ <"$f" 2>/dev/null || continue
		case "$f" in
		*.done) [ "$fa" = "$win" ] && rm -f "$f" ;; # "win pane"
		*) [ "$fb" = "$win" ] && rm -f "$f" ;;      # "kind win pid"
		esac
	done
	refresh_status
	;;
# recompute this pane's window from truth (repairs without clearing green state)
refresh)
	win=$(pane_window)
	[ -n "$win" ] || exit 0
	recompute "$win" "$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}' 2>/dev/null)"
	;;
esac
exit 0
