/**
 * attention-ping — звуковой сигнал, когда агент ждет от пользователя
 * подтверждения (опасная команда, вопрос clarify, запрос кода и т.п.).
 *
 * Что делает:
 *  - слушает ВСЕ события шлюза (host.onEvent('*')) и ловит те, чье имя
 *    похоже на запрос ввода от пользователя;
 *  - проигрывает короткий двойной "динь" через WebAudio;
 *  - шлет системное уведомление (ctx.os.notify; Windows и Mac) — сработает,
 *    даже если окно Hermes не в фокусе;
 *  - чип в статус-баре: клик = проверка звука и уведомления.
 *
 * Ставится вместе с установочным набором (plugins/attention-ping).
 */

import { cn, haptic, host, Tip } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'

const ID = 'attention-ping'

// Имена событий, которые означают "агент ждет пользователя".
// Список намеренно широкий: точные имена событий отличаются между версиями,
// поэтому ловим по подстрокам.
const ATTENTION_RE =
  /(approv|permission|confirm|clarify|question|user[_\-.]?input|input[_\-.]?request|vault|2fa|otp|code[_\-.]?request)/i

// Антиспам: не чаще одного сигнала в 4 секунды.
const THROTTLE_MS = 4000
let lastPingAt = 0
let lastEventType = ''
let pingCount = 0

let audioCtx = null

function chime() {
  try {
    const AC = window.AudioContext || window.webkitAudioContext
    if (!AC) return
    if (!audioCtx) audioCtx = new AC()
    if (audioCtx.state === 'suspended') audioCtx.resume()
    const t = audioCtx.currentTime
    const notes = [880, 1318.5] // ля - ми, короткий "динь-динь"
    notes.forEach((freq, i) => {
      const start = t + i * 0.18
      const osc = audioCtx.createOscillator()
      const gain = audioCtx.createGain()
      osc.type = 'sine'
      osc.frequency.value = freq
      gain.gain.setValueAtTime(0.0001, start)
      gain.gain.exponentialRampToValueAtTime(0.35, start + 0.02)
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.4)
      osc.connect(gain)
      gain.connect(audioCtx.destination)
      osc.start(start)
      osc.stop(start + 0.45)
    })
  } catch (e) {
    // звук не критичен - молча пропускаем
  }
}

function ping(reason) {
  const now = Date.now()
  if (now - lastPingAt < THROTTLE_MS) return
  lastPingAt = now
  pingCount += 1
  chime()
  try {
    ctx_os_notify(reason)
  } catch (e) {}
}

// Вынесено, чтобы не падать, если os-уведомления недоступны.
let ctx_os_notify = () => {}

function eventTypeOf(args) {
  // onEvent может отдавать (type, payload) или один объект { type, ... }
  const first = args[0]
  if (typeof first === 'string') return first
  if (first && typeof first === 'object') {
    if (typeof first.type === 'string') return first.type
    if (typeof first.event === 'string') return first.event
  }
  return ''
}

export default {
  id: ID,
  name: 'Attention Ping',
  register(ctx) {
    ctx_os_notify = reason =>
      ctx.os.notify({
        title: 'Hermes ждет твоего ответа',
        body: reason ? `Событие: ${reason}` : 'Агент остановился и ждет подтверждения'
      })

    ctx.i18n.register({
      ru: {
        chipTip: (count, last) =>
          `Пингую, когда агент ждет твоего ответа.\n` +
          `Сигналов за сессию: ${count}\n` +
          `Последнее событие: ${last || '—'}\n` +
          `Клик - проверить звук`,
        testDone: 'Проверка: звук + уведомление отправлены'
      },
      en: {
        chipTip: (count, last) =>
          `Pings when the agent waits for your input.\n` +
          `Pings this session: ${count}\n` +
          `Last event: ${last || '-'}\n` +
          `Click to test`,
        testDone: 'Test: sound + notification sent'
      }
    })

    // Подписка на все события шлюза.
    host.onEvent('*', (...args) => {
      const type = eventTypeOf(args)
      if (!type) return
      lastEventType = type
      if (ATTENTION_RE.test(type)) ping(type)
    })

    function Chip() {
      return jsx(Tip, {
        label: `Пингую, когда агент ждет твоего ответа. Сигналов: ${pingCount}. Клик - проверить звук`,
        children: jsx('button', {
          type: 'button',
          onClick: () => {
            haptic('tap')
            lastPingAt = 0 // тест не должен резаться антиспамом
            ping('test')
            host.notify({ kind: 'info', message: 'attention-ping: проверка звука и уведомления' })
          },
          className: cn(
            'inline-flex h-full items-center gap-1 px-1.5 text-[0.6875rem] transition-colors',
            'text-(--ui-text-tertiary) hover:bg-(--chrome-action-hover) hover:text-foreground'
          ),
          children: '\u{1F514} ping'
        })
      })
    }

    ctx.register({
      id: 'chip',
      area: 'statusBar.right',
      order: 131,
      render: () => jsx(Chip, {})
    })
  }
}
