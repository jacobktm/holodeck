#!/bin/bash
# Show current immutable overlay in bash prompt

_overlay="${IMMUTABLE_OVERLAY:-}"
if [ -z "$_overlay" ]; then
    _overlay=$(grep -oP 'subvol=\K@?[^ ,]+' /proc/self/mountinfo 2>/dev/null | head -1)
    _overlay="${_overlay#@overlay-}"
fi
if [ -n "$_overlay" ] && [ "$_overlay" != "/" ]; then
    PS1="[$_overlay] $PS1"
fi
