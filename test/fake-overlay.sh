#!/usr/bin/env bash
# Stands in for the Swift overlay: grants, then presses Pause, sends a Talk message,
# presses Resume, then Cancel — so watch.mjs can be tested with no window.
echo "GRANT 1"; sleep 1.5
echo "STOP 2"; sleep 1
echo "MSG use the left monitor"; sleep 1
echo "RESUME 3"; sleep 1
echo "CANCEL 4"
while read -r line; do [ "$line" = HIDE ] && exit 0; done
