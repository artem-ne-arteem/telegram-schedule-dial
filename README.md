# ⏰ Schedule Dial — Telegram iOS

Long-press **Send** to pick the delivery time on a dial. Drag the long hand for hours, the short one for minutes, tap the bell to send silently. No calendars, no menus — one gesture.

<video src="Media/ios.mp4" width="360"></video>

## How it works

- Long-pressing Send on a new message opens a rounded glass dome above the send button instead of the send options menu.
- **Long hand** — hour (0–23), **short hand** — minutes (5-minute steps), with a haptic tick on every step.
- The hub shows the selected time and day; a time that has already passed today becomes tomorrow.
- **Bell** on top toggles a silent send (Liquid Glass on iOS 26).
- The send button turns into a clock button: tap it to schedule, tap anywhere else to cancel.
- The message is scheduled with Telegram's own scheduled messages (`sendCurrentMessage(silentPosting:scheduleTime:)`), so it appears in Scheduled Messages and is delivered by the server as usual.
- Editing a message and the Scheduled Messages screen keep the original send options menu.

## Files

| Path | What |
|---|---|
| `ios/Feature/submodules/TelegramUI/Sources/Chat/ChatScheduleDial.swift` | The dial: overlay controller, dome, hands, bell, animations |
| `ios/Integration/telegram-ios.patch` | 12-line hook in `ChatMessageDisplaySendMessageOptions.swift` |
| `Media/ios.mp4` | Demo recorded on a device |

## Integration

Tested on [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) commit `886c8f1f11cd714bf7d5516f480caa315ecae01a` (Xcode 26).

```bash
cd Telegram-iOS
cp /path/to/this/repo/ios/Feature/submodules/TelegramUI/Sources/Chat/ChatScheduleDial.swift submodules/TelegramUI/Sources/Chat/
git apply /path/to/this/repo/ios/Integration/telegram-ios.patch
```

No new dependencies and no BUILD changes: `TelegramUI` picks up the new file through its `Sources/**` glob.

## License

GPL-2.0, as Telegram-iOS.
