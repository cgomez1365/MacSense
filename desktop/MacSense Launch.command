#!/bin/bash
# MacSense Launcher — double-click to open dashboard

DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=58249
PIDFILE="$DIR/.macsense.pid"

# If server is already running, just open Chrome and exit
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "MacSense already running (PID $OLD_PID). Opening dashboard..."
        open -a "Google Chrome" --args --app="http://127.0.0.1:$PORT" --window-size=1060,760
        exit 0
    fi
fi

# Kill anything on port just in case
lsof -ti :$PORT 2>/dev/null | xargs kill -9 2>/dev/null
sleep 0.3

# Start server detached from this terminal (nohup keeps it alive after Terminal closes)
nohup python3 "$DIR/MacSense/app.py" > "$DIR/.macsense.log" 2>&1 &
SERVER_PID=$!
echo $SERVER_PID > "$PIDFILE"
echo "MacSense server started (PID $SERVER_PID)"

# Wait until server responds (up to 6 seconds)
for i in {1..20}; do
    if curl -s --max-time 1 "http://127.0.0.1:$PORT" > /dev/null 2>&1; then
        echo "Server ready!"
        break
    fi
    sleep 0.3
done

# Open the dashboard in Chrome kiosk/app mode
open -a "Google Chrome" --args --app="http://127.0.0.1:$PORT" \
    --window-size=1060,760 \
    --window-position=120,60 \
    --no-first-run \
    --disable-extensions

echo "Dashboard opened. Server stays alive in background."
echo "To stop: kill $(cat "$PIDFILE") or re-run this script."
