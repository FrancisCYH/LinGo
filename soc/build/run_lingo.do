# Waveform logging + progress timestamps for LinGo CGRA simulation.
# Sourced by run_lingo.sh; echoes the current sim time every 10 ms.
# At the default 115200 baud the UART TX drain (~87 us/char) stretches the
# run to ~30 ms of sim time, hence the 40 ms window.
do log_lingo.do
echo "=== sim start: [now] ==="
run 10 ms
echo "=== reached 10 ms: [now] ==="
run 10 ms
echo "=== reached 20 ms: [now] ==="
run 10 ms
echo "=== reached 30 ms: [now] ==="
run 10 ms
echo "=== reached 40 ms: [now] ==="
quit
