#!/usr/bin/env bash
# Фича media: окружение для расшифровки (faster-whisper + субтитры YouTube). Одно на сервер, в корне Hermes.
set -euo pipefail
V="$ROOT/.venv-media"
if [ -x "$V/bin/python" ] && "$V/bin/python" -c 'import faster_whisper, youtube_transcript_api' 2>/dev/null; then
  echo "     окружение расшифровки уже есть"
elif [ "${MEDIA_SKIP_INSTALL:-0}" = 1 ]; then
  echo "     ! установку окружения пропустил (MEDIA_SKIP_INSTALL=1)"
elif command -v uv >/dev/null 2>&1; then
  echo "     ставлю окружение расшифровки (1-3 минуты)..."
  uv venv -q "$V" && uv pip install -q -p "$V/bin/python" faster-whisper youtube-transcript-api
  echo "     + окружение: $V"
else
  python3 -m venv "$V" && "$V/bin/pip" install -q faster-whisper youtube-transcript-api && echo "     + окружение: $V"
fi
printf '%s\n' "$V/bin/python" > "$PROFILE/local/media-python"
command -v ffmpeg >/dev/null 2>&1 || echo "     ! нет ffmpeg - видео не расшифруется. На сервере: sudo apt-get install -y ffmpeg"
