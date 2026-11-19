#!/bin/sh
session=$(jq -r '.session_id')
grep -qx "$session" "$HOME/Library/Application Support/Hop/caffeinated-sessions" 2>/dev/null && echo "☕ caffeinated"
exit 0
