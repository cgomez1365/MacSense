#!/bin/bash
# MacSense Launcher
# Double-click this file to open MacSense Dashboard

DIR="$(cd "$(dirname "$0")" && pwd)"

# Kill any old server on this port
lsof -ti :58249 2>/dev/null | xargs kill -9 2>/dev/null
sleep 0.2

# Start the Python server
python3 "$DIR/app.py" &
SERVER_PID=$!

echo "Starting MacSense server (PID $SERVER_PID)..."

# Wait until it responds
for i in {1..20}; do
    if curl -s --max-time 1 http://127.0.0.1:58249 > /dev/null 2>&1; then
        echo "Server ready!"
        break
    fi
    sleep 0.3
done

# Open Chrome in app (kiosk) mode - standalone frameless window
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --app=http://127.0.0.1:58249 \
  --window-size=960,700 \
  --window-position=160,80 \
  --no-first-run \
  --disable-extensions \
  2>/dev/null

# When Chrome closes, kill the server too
kill $SERVER_PID 2>/dev/null
