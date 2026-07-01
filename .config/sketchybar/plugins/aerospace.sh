#!/usr/bin/env bash


main() {
    local workspace="$1"
    local focused_workspace="${FOCUSED_WORKSPACE:-}"
    local monitor_id
    local window_count

    if [ -z "$focused_workspace" ]; then
        focused_workspace="$(aerospace list-workspaces --focused)"
    fi

    monitor_id="$(
        aerospace list-workspaces --all --format '%{workspace}|%{monitor-id}' \
            | awk -F'|' -v workspace="$workspace" '$1 == workspace { print $2; exit }'
    )"
    if [ -z "$monitor_id" ]; then
        monitor_id="$(aerospace list-monitors --focused --format '%{monitor-id}')"
    fi

    if [ "$workspace" = "$focused_workspace" ]; then
        sketchybar --set "$NAME" background.drawing=on display="$monitor_id"
        return
    fi

    window_count="$(aerospace list-windows --workspace "$workspace" --count)"
    if [ "${window_count:-0}" -gt 0 ] 2>/dev/null; then
        sketchybar --set "$NAME" background.drawing=off display="$monitor_id"
    else
        sketchybar --set "$NAME" background.drawing=off display=0
    fi
}


if [ "$SENDER" = aerospace_workspace_change ] || [ "$SENDER" = aerospace_focus_change ]; then
    main "$@"
fi
