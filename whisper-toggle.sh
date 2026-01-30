#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

MIC_PRIORITY=(
  "RODECaster Pro Stereo"
  "AirPods Pro"
  "NexiGo N60 FHD Webcam"
  "MacBook Pro Microphone"
)

LOG_FILE="/tmp/whisper-toggle.log"
LOCK_DIR="/tmp/whisper.lock.d"
PID_FILE="/tmp/whisper-recording.pid"
MODE_FILE="/tmp/whisper-mode"
WAV_FILE="/tmp/whisper-recording.wav"
OUT_DIR="/tmp/mlx_whisper_out"
OUT_TXT="${OUT_DIR}/whisper-recording.txt"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "busy; ignoring cmd=$1"
    exit 0
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}

cleanup_temp() {
  rm -f "$WAV_FILE"
  rm -f "$OUT_TXT"
  rmdir "$OUT_DIR" 2>/dev/null || true
}

cleanup_stale() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -z "${pid:-}" ] || ! kill -0 "$pid" 2>/dev/null; then
      log "stale pid; cleaning state"
      rm -f "$PID_FILE" "$MODE_FILE"
    fi
  fi
}

recording_active() {
  cleanup_stale
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

current_mode() {
  if [ -f "$MODE_FILE" ]; then
    cat "$MODE_FILE" 2>/dev/null || true
  fi
}

detect_mic() {
  local devices
  devices="$(/opt/homebrew/bin/ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true)"
  for name in "${MIC_PRIORITY[@]}"; do
    local idx
    idx="$(echo "$devices" | grep -i "audio" -A 50 | grep -i "$name" | head -1 | sed 's/.*\[\([0-9]*\)\].*/\1/')"
    if [ -n "$idx" ]; then
      log "mic selected: [$idx] $name"
      echo ":$idx"
      return 0
    fi
  done
  log "no preferred mic found; falling back to :0"
  echo ":0"
}

play_sound() {
  local sound="$1"
  ( afplay "$sound" >/dev/null 2>&1 ) &
}

wait_for_pid_exit() {
  local pid="$1"
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
      log "ffmpeg did not exit after 5s; force killing"
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
  done
}

start_recording() {
  local mode="$1"
  if recording_active; then
    log "start ignored; already recording"
    return 0
  fi

  rm -f "$WAV_FILE"
  printf '%s' "$mode" >"$MODE_FILE"

  local mic
  mic="$(detect_mic)"

  /opt/homebrew/bin/ffmpeg -f avfoundation -i "$mic" -ac 1 -ar 16000 -sample_fmt s16 \
    -thread_queue_size 512 -fflags +nobuffer -y "$WAV_FILE" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  printf '%s' "$pid" >"$PID_FILE"

  log "recording started pid=$pid mode=$mode"
  play_sound "/System/Library/Sounds/Tink.aiff"
}

do_transcribe_and_paste() {
  if [ ! -f "$WAV_FILE" ]; then
    log "wav missing; aborting transcription"
    return 0
  fi

  local filesize
  filesize="$(stat -f%z "$WAV_FILE" 2>/dev/null || echo 0)"
  if [ "$filesize" -lt 1000 ]; then
    log "wav too small (${filesize}b); aborting"
    cleanup_temp
    return 0
  fi

  mkdir -p "$OUT_DIR"
  rm -f "$OUT_TXT"
  log "transcription started"

  if /opt/homebrew/bin/mlx_whisper "$WAV_FILE" \
    --model mlx-community/whisper-large-v3-turbo \
    --output-format txt --output-dir "$OUT_DIR" --language en >>"$LOG_FILE" 2>&1; then
    if [ -f "$OUT_TXT" ]; then
      sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "$OUT_TXT" | pbcopy
      osascript -e 'tell application "System Events" to keystroke "v" using command down' >>"$LOG_FILE" 2>&1 || log "osascript paste failed"
      log "paste completed"
    else
      log "output txt missing after transcription"
    fi
  else
    log "mlx_whisper failed"
  fi

  cleanup_temp
}

stop_recording_and_transcribe() {
  if ! recording_active; then
    log "stop ignored; not recording"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"

  log "stopping pid=$pid"
  play_sound "/System/Library/Sounds/Pop.aiff"

  if [ -n "${pid:-}" ]; then
    kill -INT "$pid" 2>>"$LOG_FILE" || true
    wait_for_pid_exit "$pid"
  fi

  rm -f "$PID_FILE" "$MODE_FILE"

  # Release lock before backgrounding transcription
  rmdir "$LOCK_DIR" 2>/dev/null || true
  trap - EXIT

  ( do_transcribe_and_paste ) &
  log "transcription spawned pid=$!"
}

switch_to_toggle() {
  if recording_active; then
    local mode
    mode="$(current_mode)"
    if [ "$mode" = "hold" ]; then
      printf 'toggle' >"$MODE_FILE"
      log "switched to toggle"
    fi
  fi
}

main() {
  if [ $# -ne 1 ]; then
    echo "Usage: $0 {toggle|hold-start|release|switch-to-toggle}" >&2
    exit 1
  fi

  local cmd="$1"
  acquire_lock "$cmd"

  case "$cmd" in
    toggle)
      if recording_active; then
        local mode
        mode="$(current_mode)"
        if [ -z "$mode" ] || [ "$mode" = "toggle" ]; then
          stop_recording_and_transcribe
        else
          log "toggle ignored; mode=$mode"
        fi
      else
        start_recording "toggle"
      fi
      ;;
    hold-start)
      if recording_active; then
        log "hold-start ignored; already recording"
      else
        start_recording "hold"
      fi
      ;;
    release)
      if recording_active; then
        local mode
        mode="$(current_mode)"
        if [ "$mode" = "hold" ]; then
          stop_recording_and_transcribe
        else
          log "release ignored; mode=$mode"
        fi
      else
        log "release ignored; idle"
      fi
      ;;
    switch-to-toggle)
      switch_to_toggle
      ;;
    *)
      echo "Usage: $0 {toggle|hold-start|release|switch-to-toggle}" >&2
      exit 1
      ;;
  esac
}

main "$@"
