# BRO

BRO is a small voice assistant for the Mac. A glowing orb floats on your screen, listens to you, and answers out loud.
Hearing, thinking and speaking all run on your Mac. No account, no API key.

- **Hearing:** [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Whisper small, multilingual). You can speak English, Hindi or Hinglish; BRO hears it as English text.
- **Thinking:** Llama 3.2 3B Instruct (4-bit) running locally with [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).
- **Speaking:** the built-in macOS voice.

## Requirements

- A Mac with Apple Silicon (M1 or newer). Intel Macs do not work.
- macOS 14 or newer.
- About 3 GB free disk space. On first run BRO downloads its models (about 2.5 GB) once, so you need internet the first time.

## Install (the easy way)

1. Download `BRO.dmg` from the **Releases** page of this repo.
2. Open it and drag **BRO** into **Applications**.
3. The first time, macOS will say it cannot check the app, because this app is not signed with a paid Apple Developer account. To open it anyway, do one of these:
   - Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to BRO.
   - Or open **Terminal** and run: `xattr -dr com.apple.quarantine /Applications/BRO.app`
4. Allow **Microphone** when asked.
5. Some commands need more permissions, and macOS will ask when you first use them:
   - **Screen Recording**: for "take a screenshot".
   - **Accessibility**: for keyboard commands like "new tab" or "scroll down", and for "type ...".

## How to use it

- BRO listens by itself. Just speak, and it answers when you stop talking.
- Show or hide the orb: **Option + B**.
- Say "text bar" to type to BRO instead of speaking.
- While BRO is playing its own songs it cannot hear you over the music. In that case, hold **Option + Space** while you speak, and let go when you are done. You can also press it to make BRO stop talking.

## What you can say

Say these in your own words. BRO understands many ways to say the same thing, and short sentences work best.

**Apps and web**
- "open WhatsApp", "close Safari", "open YouTube in Brave"
- "go to Flipkart", "search best phones", "look up python tutorial"
- "open downloads", "open the desktop folder"

**Music**
- "play kesariya" (songs in `~/Music/songs` first, then YouTube Music)
- "play lofi on YouTube", "play a random song", "pause", "next song", "stop music"

**Mac controls**
- "volume up", "volume 40", "mute", "brightness 50", "make it brighter"
- "dark mode", "lock screen", "take a screenshot" (saved in Pictures > BRO Screenshots)
- "turn wifi off", "keyboard light on", "empty trash"
- "new tab", "refresh", "scroll down", "copy", "paste", "full screen"
- "which app uses the most memory", "battery", "disk space", "ip address"

**Time, reminders and notes**
- "what time is it", "what is the date", "set a timer for 10 minutes", "set an alarm for 7 AM"
- "remind me to call mom at 5 pm", "remind me every day at 9 am to take medicine"
- "take a note buy milk", "add milk and eggs to my list", "what is on my list"
- "start stopwatch", "pomodoro"

**Questions and helpers**
- "what's the weather", "is it raining outside", "news", "cricket score"
- "who is Albert Einstein", "define serendipity", "what is 245 times 18", "20 percent of 500"
- "10 km to miles", "100 dollars in rupees", "bitcoin price", "flip a coin"
- "write an email to my teacher saying I am sick", "summarize this page", "summarize clipboard"
- "remember that my car key is in the drawer", "what do you remember"

**BRO itself**
- "make the orb red", "talk slower", "repeat that", "help", "bro shutdown"
- You can chain commands: "open Brave and search lofi".

Anything BRO does not know as a command goes to the AI, which can chat and answer questions, but cannot control your Mac.

## Does it work offline?

Mostly yes. After the first-run download, hearing, thinking and speaking work without internet, and so do apps, volume, brightness, timers, alarms, reminders, notes, lists, sums, unit conversions, screenshots and keyboard commands.

These need internet:
- weather, news and cricket scores
- currency conversion and crypto prices
- Wikipedia answers ("who is ...", "what is ...") and word meanings
- playing songs from YouTube or YouTube Music, and opening websites

## Build it yourself

You need Xcode (free, from the App Store).

```
xcodebuild -downloadComponent MetalToolchain
bash build_app.sh
```

The first build takes 10 to 25 minutes. The app is created in `~/Applications/BRO.app`.
To make a `.dmg`: `bash make_dmg.sh` (the file appears in `dist/`).

## Make it yours

Open `Sources/BRO/BRO.swift` and look at the "Easy settings" at the top: your name (`userName`), home city for the weather (`homeCity`, `homeLat`, `homeLon`), voice, speech speed and talk key. The brain model is set in `Sources/BRO/Brain.swift`.

## License

MIT. See `LICENSE`.
