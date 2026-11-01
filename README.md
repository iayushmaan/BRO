# BRO

BRO is a small voice assistant for the Mac. A glowing orb floats on your screen, listens to you, and answers out loud.
Everything runs on your Mac: hearing, thinking and speaking. No account, no API key.

- **Hearing:** [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Whisper small, multilingual). You can speak English, Hindi or Hinglish; BRO hears it as English text.
- **Thinking:** Llama 3.2 3B Instruct (4-bit) running locally with [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).
- **Speaking:** the built-in macOS voice.
- Push to talk: hold **Option + Space**.

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
4. Allow **Microphone** when asked. Some commands also need **Accessibility** (System Settings > Privacy & Security > Accessibility).

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
