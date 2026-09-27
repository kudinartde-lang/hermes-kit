---
name: local-media-transcription
description: "Use when transcribing audio, video, voice notes, or YouTube links."
version: 1.0.0
metadata:
  hermes:
    tags: [Transcription, Translation, Audio, Video, YouTube]
    related_skills: [youtube-content]
---

# Расшифровка аудио и видео

Человек присылает голосовые, записи встреч, видео и ссылки на YouTube и ждёт текст, выжимку или перевод.
Этот путь работает всегда, даже когда YouTube блокирует сервер.

## Окружение (ставит фича media)

- Отдельное окружение `<корень Hermes>/.venv-media` с `faster-whisper` и `youtube-transcript-api`.
- Путь к его питону - в файле `local/media-python` помощника. Нет окружения:
  `uv venv <корень>/.venv-media && uv pip install -p <корень>/.venv-media/bin/python faster-whisper youtube-transcript-api`
  (обычный pip на новых системах заблокирован - PEP 668).
- Для видео нужен ffmpeg (`ffmpeg -version`; нет - сказать тому, кто обслуживает сервер: `apt-get install ffmpeg`).

## Порядок

1. **Прислали файл (аудио/видео)** -> расшифровать на сервере (рецепт ниже). Самый надёжный путь.
   Голосовые больше 20 МБ в Telegram не доходят - попросить разбить на части.
2. **Ссылка на YouTube** -> сначала субтитры через youtube-transcript-api. Если YouTube отвечает "blocked / sign in to confirm you're not a bot" (адрес сервера из дата-центра) - не повторять и не искать зеркала. Попросить файл.
3. **Песни и распевы** -> распознавание пения всегда приблизительное. Сказать об этом, отметить сомнительные строки, не выдумывать чистый текст.

## Рецепт faster-whisper

```python
from faster_whisper import WhisperModel
model = WhisperModel("small", device="cpu", compute_type="int8")   # речь
segments, info = model.transcribe(path, beam_size=5, vad_filter=True)
text = " ".join(s.text.strip() for s in segments)
```

- Речь, интервью, встречи: модель `small`, VAD включён, язык определяется сам.
- Музыка и шумное аудио: модель `medium` (скачает ~1,5 ГБ, на процессоре несколько минут - запускать в фоне с уведомлением), язык указать явно, `vad_filter=False`, `temperature=0.0`, `condition_on_previous_text=False`.
- Длинная запись (час и больше) - в фоне с уведомлением, не в коротком ожидании.

## Что отдавать

- По-русски, простыми словами.
- Встречи и интервью: полный текст сохранить в файл (cache/ или личная папка), в ответ - то, что просили: задачи, решения, выжимку. Задачи с датами - предложить занести в календарь, если стоит фича календаря.
- Песни: что за трек, перевод по смыслу по куплетам, сомнительные места отмечены.
