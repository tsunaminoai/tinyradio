#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Profile an optimized build so the numbers reflect real behavior.
devbox run -- zig build -Doptimize=ReleaseFast

# perf needs root for call graphs. Records a root-owned perf.data, so chown it
# back afterwards so the report can be read without sudo.
# A perf.data left by an earlier run can't be overwritten, so remove it first.
rm -f perf.data

# Record process details once the app is up, without garbling the TUI:
# the info goes to perf-process.txt.
(
    pid=""
    for _ in $(seq 100); do
        pid=$(pgrep -x tinyradio | head -n 1 || true)
        [ -n "$pid" ] && break
        sleep 0.1
    done
    if [ -n "$pid" ]; then
        {
            ps -p "$pid" -o pid,ppid,%cpu,%mem,etime,cmd
            pmap -x "$pid" | tail -n 5
        } > perf-process.txt 2>&1
    fi
) &

echo "Running perf: press 'q' to stop the program; perf will then finish."
# perf record exits with the app's status, so a failed launch is caught here.
# Only perf needs root. The app runs as you: PulseAudio refuses root clients on
# your user's socket, so perf launches the app through runuser.
status=0
sudo env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}" \
    nix run nixpkgs#perf -- record -g -e cycles,task-clock -o perf.data \
    -- runuser -u "$(id -un)" -- ./zig-out/bin/tinyradio || status=$?
sudo chown "$(id -u):$(id -g)" perf.data

if [ "$status" -ne 0 ]; then
    # The profile would only cover a failed launch, so don't keep it.
    rm -f perf.data
    echo "tinyradio exited with status $status; no report generated." >&2
    exit "$status"
fi

nix run nixpkgs#perf -- report -i perf.data
