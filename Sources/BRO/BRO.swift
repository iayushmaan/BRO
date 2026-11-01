import SwiftUI
import AppKit
import QuartzCore
import Carbon.HIToolbox
import AVFoundation
import WhisperKit
import ApplicationServices
import ServiceManagement

// MARK: - Orb states

enum OrbState: String, CaseIterable {
    case idle = "Idle", listening = "Listening", thinking = "Thinking", speaking = "Speaking"

    var index: Int { OrbState.allCases.firstIndex(of: self) ?? 0 }

    // Distinct colour per state
    var rgb: (Double, Double, Double) {
        switch self {
        case .idle:      return (0.30, 0.55, 1.00)   // calm indigo-blue
        case .listening: return (0.30, 0.55, 1.00)   // same calm blue as idle
        case .thinking:  return (0.70, 0.45, 1.00)   // violet
        case .speaking:  return (1.00, 0.72, 0.30)   // warm amber
        }
    }
    var energy: Double {
        switch self {
        case .idle:      return 0.35
        case .listening: return 0.70
        case .thinking:  return 0.60
        case .speaking:  return 1.00
        }
    }
    var spinSpeed: Double {
        switch self {
        case .idle:      return 0.25
        case .listening: return 0.60
        case .thinking:  return 2.40
        case .speaking:  return 0.90
        }
    }
    func pulse(_ t: Double) -> Double {
        switch self {
        case .idle:      return 0.04 * sin(t * 1.3)
        case .listening: return 0.06 * sin(t * 3.0)
        case .thinking:  return 0.03 * sin(t * 5.0)
        case .speaking:  return 0.09 * (0.5 + 0.5 * sin(t * 9.0)) * (0.65 + 0.35 * sin(t * 3.7 + 1.0))
        }
    }
}

// MARK: - Smooth blending between states

// The orb colour. nil = BRO's normal colours (blue, violet, amber). Say "make the orb red" or "default colour".
var orbTint: (Double, Double, Double)? = nil
let orbColorChoices: [String: (Double, Double, Double)] = [
    "red": (1.00, 0.28, 0.28), "orange": (1.00, 0.55, 0.20), "yellow": (1.00, 0.85, 0.25),
    "green": (0.30, 0.85, 0.45), "blue": (0.15, 0.40, 1.00), "purple": (0.62, 0.35, 1.00),
    "pink": (1.00, 0.45, 0.75), "white": (0.95, 0.95, 1.00), "cyan": (0.25, 0.85, 1.00)
]
let orbColorAliases: [String: String] = ["violet": "purple", "gold": "yellow", "golden": "yellow", "magenta": "pink", "aqua": "cyan"]

func setOrbColor(_ name: String) {
    if name == "default" {
        orbTint = nil
        UserDefaults.standard.removeObject(forKey: "broOrbColor")
    } else if let c = orbColorChoices[name] {
        orbTint = c
        UserDefaults.standard.set(name, forKey: "broOrbColor")
    }
}

func loadOrbColor() {
    if let n = UserDefaults.standard.string(forKey: "broOrbColor"), let c = orbColorChoices[n] { orbTint = c }
}

final class StateMix {
    var w: [Double] = [1, 0, 0, 0]
    var spin: Double = 0
    var level: Double = 0
    var last: Double = 0

    func update(_ s: OrbState, now: Double, level target: Double) {
        let dt = last == 0 ? 0 : min(now - last, 0.1)
        last = now
        let k = 1 - exp(-dt * 4.0)
        for i in 0..<4 {
            let target: Double = (i == s.index) ? 1.0 : 0.0
            w[i] += (target - w[i]) * k
        }
        spin += mix { $0.spinSpeed } * dt
        level += (target - level) * (1 - exp(-dt * 12))
    }

    func mix(_ f: (OrbState) -> Double) -> Double {
        var sum = 0.0
        for s in OrbState.allCases { sum += w[s.index] * f(s) }
        return sum
    }

    func rgb() -> (Double, Double, Double) {
        if let c = orbTint { return c }
        return (mix { $0.rgb.0 }, mix { $0.rgb.1 }, mix { $0.rgb.2 })
    }
}

final class OrbModel: ObservableObject {
    @Published var state: OrbState = .idle
    var activationStart: Double = -1000
    var onReplay: (() -> Void)?
    var micLevel: Double = 0
    var onChangeShortcut: (() -> Void)?
    @Published var shortcutLabel = "⌥ B"

    func triggerActivation() {
        activationStart = Date().timeIntervalSinceReferenceDate
    }
}

// MARK: - Helpers

func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

func smoothstep(_ x: Double, _ a: Double, _ b: Double) -> Double {
    let u = min(1, max(0, (x - a) / (b - a)))
    return u * u * (3 - 2 * u)
}

func circlePath(_ r: Double, at p: CGPoint = .zero) -> Path {
    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}

// MARK: - Drawing

func drawOrb(_ ctx: inout GraphicsContext, size: CGSize, now t: Double, m: StateMix, p: Double) {
    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
    let R = min(size.width, size.height) * 0.16
    let rgb = m.rgb()
    let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    let energy = min(1, m.mix { $0.energy } + m.w[1] * m.level * 0.5)
    let wL = m.w[1], wT = m.w[2], wS = m.w[3]

    // Activation: the orb glides up from below the screen edge (the window itself moves)
    let orbAlpha = smoothstep(p, 0.0, 0.45)

    // The orb itself (drawn around the origin)
    ctx.translateBy(x: centre.x, y: centre.y)
    let appear = 0.7 + 0.3 * easeOut(p)
    ctx.scaleBy(x: appear, y: appear)
    ctx.opacity = orbAlpha

    let r = R * (1 + m.mix { $0.pulse(t) } + m.w[1] * m.level * 0.55)

    // Soft outer glow
    ctx.drawLayer { layer in
        layer.addFilter(.blur(radius: R * 0.55))
        let gr = R * (2.0 + 0.3 * energy)
        layer.fill(circlePath(gr), with: .color(color.opacity(0.18 + 0.25 * energy)))
    }

    // Faint guide ring
    ctx.stroke(circlePath(R * 1.5), with: .color(color.opacity(0.12)), lineWidth: 1)

    // Rotating arc rings
    for i in 0..<3 {
        let rr = R * (1.5 + 0.38 * Double(i))
        let dir: Double = (i % 2 == 0) ? 1 : -1
        let a = m.spin * dir * (1 + 0.35 * Double(i)) + Double(i) * 1.1
        for (start, len) in [(0.0, 1.2), (Double.pi, 0.7)] {
            var arc = Path()
            arc.addArc(center: .zero, radius: rr,
                       startAngle: .radians(a + start), endAngle: .radians(a + start + len),
                       clockwise: false)
            ctx.stroke(arc, with: .color(color.opacity(0.35 + 0.5 * energy - 0.1 * Double(i))),
                       style: StrokeStyle(lineWidth: 1.2 + energy, lineCap: .round))
        }
    }

    // Listening: expanding ripples
    if wL > 0.01 {
        for k in 0..<3 {
            let ph = (t * 0.55 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let rr = R * (1.15 + ph * 1.5)
            ctx.stroke(circlePath(rr), with: .color(color.opacity((1 - ph) * 0.55 * wL)), lineWidth: 1.5)
        }
    }

    // Thinking: orbiting dots
    if wT > 0.01 {
        for k in 0..<6 {
            let a = m.spin * 2.2 + Double(k) * Double.pi / 3
            let pt = CGPoint(x: cos(a) * R * 1.3, y: sin(a) * R * 1.3)
            let dr = 2.5 + 1.5 * sin(t * 4 + Double(k))
            ctx.fill(circlePath(dr, at: pt), with: .color(color.opacity(0.9 * wT)))
        }
    }

    // Speaking: living waveform ring
    if wS > 0.01 {
        var wave = Path()
        let n = 96
        for j in 0...n {
            let a = Double(j) / Double(n) * 2 * Double.pi
            let wob = sin(a * 5 + t * 6) * 0.6 + sin(a * 9 - t * 9) * 0.4
            let rad = R * 1.22 + R * 0.14 * wS * wob * (0.6 + 0.4 * sin(t * 3.1))
            let pt = CGPoint(x: cos(a) * rad, y: sin(a) * rad)
            if j == 0 { wave.move(to: pt) } else { wave.addLine(to: pt) }
        }
        wave.closeSubpath()
        ctx.stroke(wave, with: .color(color.opacity(0.85 * wS)), lineWidth: 1.8)
    }

    // Core
    let core = Gradient(stops: [
        .init(color: Color.white.opacity(0.95), location: 0.0),
        .init(color: color.opacity(0.95), location: 0.35),
        .init(color: color.opacity(0.35), location: 0.75),
        .init(color: color.opacity(0.0), location: 1.0)
    ])
    ctx.fill(circlePath(r * 1.25),
             with: .radialGradient(core, center: .zero, startRadius: 0, endRadius: r * 1.25))
    ctx.stroke(circlePath(r), with: .color(color.opacity(0.5)), lineWidth: 1)
}

// MARK: - SwiftUI view

struct OrbView: View {
    @ObservedObject var model: OrbModel
    @State private var mix = StateMix()

    var body: some View {
        TimelineView(.animation(minimumInterval: model.state == .idle ? 1.0 / 24.0 : 1.0 / 60.0)) { tl in
            orb(at: tl.date.timeIntervalSinceReferenceDate)
        }
        .contextMenu {
            ForEach(OrbState.allCases, id: \.self) { s in
                Button(s.rawValue) { model.state = s }
            }
            Divider()
            Button("Replay activation") { model.onReplay?() }
            Button("Change shortcut… (\(model.shortcutLabel))") { model.onChangeShortcut?() }
            Button("Quit BRO") { NSApp.terminate(nil) }
        }
    }

    func orb(at now: Double) -> some View {
        mix.update(model.state, now: now, level: model.micLevel)
        let m = mix
        let p = min(1, max(0, (now - model.activationStart) / 1.8))
        return Canvas { ctx, size in
            drawOrb(&ctx, size: size, now: now, m: m, p: p)
        }
    }
}

// MARK: - Global keyboard shortcut (needs no special permission)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    let hotID: UInt32
    var onPress: (() -> Void)?

    init(id: UInt32 = 1, onPress: @escaping () -> Void) {
        self.hotID = id
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            guard hk.id == me.hotID else { return OSStatus(eventNotHandledErr) }   // another key's event
            DispatchQueue.main.async { me.onPress?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x42524F21), id: hotID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }
}

// A key that is held down: onDown when pressed, onUp when let go (used for push-to-talk).
final class HoldKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    init() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.id == 2 else { return OSStatus(eventNotHandledErr) }   // not the talk key
            let me = Unmanaged<HoldKey>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { if pressed { me.onDown?() } else { me.onUp?() } }
            return noErr
        }, 2, &specs, selfPtr, &handlerRef)
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let id = EventHotKeyID(signature: OSType(0x42524F22), id: 2)
        return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

func keyName(_ e: NSEvent) -> String {
    switch Int(e.keyCode) {
    case kVK_Space: return "Space"
    case kVK_Return: return "Return"
    case kVK_Tab: return "Tab"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    default:
        if let c = e.charactersIgnoringModifiers, let u = c.unicodeScalars.first, u.value >= 33, u.value < 0xF700 {
            return c.uppercased()
        }
        return "Key \(e.keyCode)"
    }
}

func shortcutText(_ mods: UInt32, _ key: String) -> String {
    var t = ""
    if mods & UInt32(controlKey) != 0 { t += "⌃ " }
    if mods & UInt32(optionKey) != 0 { t += "⌥ " }
    if mods & UInt32(shiftKey) != 0 { t += "⇧ " }
    if mods & UInt32(cmdKey) != 0 { t += "⌘ " }
    return t + key
}

// MARK: - Microphone (only runs while BRO is visible and listening)

final class MicMonitor {
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private(set) var running = false
    var lastChunk = Date()                      // v53: when the last piece of sound arrived (used to detect a dead microphone)
    var onChunk: ((Double, [Float]) -> Void)?   // (loudness, 16 kHz mono samples)

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default:
            done(false)
        }
    }

    func start() throws {
        if running && engine.isRunning { return }
        if running { stop() }                   // v53: BRO thought the mic was on, but the audio engine had stopped
        lastChunk = Date()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let tgt = target
        guard let converter = AVAudioConverter(from: format, to: tgt) else {
            throw NSError(domain: "BRO", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio converter"])
        }
        let ratio = tgt.sampleRate / format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: tgt, frameCapacity: cap) else { return }
            var supplied = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ch = out.floatChannelData?[0] else { return }
            let n = Int(out.frameLength)
            if n == 0 { return }
            let samples = Array(UnsafeBufferPointer(start: ch, count: n))
            var sum: Float = 0
            for v in samples { sum += v * v }
            let rms = Double(sqrt(sum / Float(n)))
            DispatchQueue.main.async { self?.lastChunk = Date(); self?.onChunk?(rms, samples) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

// Decides when you started and finished a sentence.
final class Endpointer {
    private var buffer: [Float] = []
    private var preroll: [[Float]] = []
    private var speaking = false
    private var floor = 0.01
    private var speechStart = 0.0
    private var lastVoice = 0.0
    var relaxed = false          // true while BRO waits for a short "yes" or "no": quieter and shorter sounds count

    func reset() { buffer = []; preroll = []; speaking = false }

    func feed(rms: Double, samples: [Float], now: Double) -> [Float]? {
        if !speaking {
            preroll.append(samples)
            if preroll.count > 14 { preroll.removeFirst() }
            if rms > (relaxed ? max(0.012, floor * 2.2) : max(0.02, floor * 3)) {
                speaking = true
                speechStart = now
                lastVoice = now
                buffer = preroll.flatMap { $0 }
                preroll = []
            } else {
                floor = floor * 0.98 + rms * 0.02
            }
            return nil
        }
        buffer += samples
        if rms > max(0.012, floor * 2) { lastVoice = now }
        if now - lastVoice > silenceWait || now - speechStart > 25 {
            speaking = false
            let voiced = lastVoice - speechStart
            let out = buffer
            buffer = []
            return voiced >= (relaxed ? 0.1 : 0.35) ? out : nil
        }
        return nil
    }
}

// MARK: - Floating transparent window

final class OrbPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - BRO's personality (the brain itself is in Brain.swift: model, idle time, reply length)

// How BRO SAYS certain words out loud (the text on screen stays as written). If a name sounds wrong, change the right side.
let spokenSpellings: [String: String] = [:]
let userName = "friend"                          // BRO calls you this (change it to your own name)
let batteryWarnings = true                       // BRO says it out loud when the battery is low (20, 10 and 5 percent) and not charging
// MARK: - Easy settings (change a value, then rebuild the app)

let broName = "BRO"
let personality = "friendly, a little witty and relaxed, like a good friend"
let replyLength = "one or two short spoken sentences"
let voiceName = "Daniel"                          // part of a voice name from System Settings > Accessibility > Spoken Content
let speechRate: Float = 0.5                       // 0.0 slow ... 1.0 fast (0.5 is normal)
let pushToTalk = true                            // true: the talk key works, and while BRO plays its own songs you hold it to talk. false: no talk key
let talkKeyCode = UInt32(kVK_Space)              // the key to hold ...
let talkKeyMods = UInt32(optionKey)              // ... together with this one: Option + Space
let silenceWait = 1.1                             // seconds of quiet before BRO decides you have finished talking
let hearHindiAsEnglish = true                      // true: you can speak Hindi / Hinglish / English and BRO hears it as English text. false: English only (old way)
let whisperModel = hearHindiAsEnglish ? "openai_whisper-small" : "openai_whisper-small.en"   // the multilingual one downloads once
let useWikipedia = true                           // true: "who is / what is" questions are answered from Wikipedia (needs internet). false: the built-in brain always answers

// Hook for fixing how your name is written on screen (does nothing for "friend").
func fixName(_ text: String) -> String {
    text
}

func spokenForm(_ text: String) -> String {
    var out = text
    for (written, said) in spokenSpellings {
        out = out.replacingOccurrences(of: written, with: said, options: [.caseInsensitive])
    }
    return out
}

// Things the user asked BRO to remember (kept only on this Mac, in UserDefaults).
func loadFacts() -> [String] { UserDefaults.standard.stringArray(forKey: "broFacts") ?? [] }
func saveFacts(_ f: [String]) { UserDefaults.standard.set(Array(f.suffix(30)), forKey: "broFacts") }

func makeSystemPrompt() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "EEEE, d MMMM yyyy, h:mm a"
    var parts: [String] = [
        "You are \(broName), a small honest voice assistant that runs on the user's MacBook, and you are \(personality).",
        "Call the user \(userName). If the user says how they want to be called, or corrects how a word is written or pronounced, they are right: apologise briefly and carry on.",
        "The user lives in \(homeCity), India. Right now it is \(f.string(from: Date())).",
        "Always reply in English only, even if the user mixes in other languages.",
        "Keep every reply to \(replyLength). Plain text only: no emojis, lists, or markdown.",
        "Opening and closing apps, quitting BRO, playing songs from this Mac and YouTube, brightness, calendar, running Shortcuts, Wi-Fi, timers, alarms, reminders, notes, volume, music keys, searching the web, the time, date, weather, news and sums are handled separately before you hear the request, so you cannot do other things on the Mac yourself, and you must never pretend you did.",
        "You cannot see or check the battery, the running apps, the storage, the security or any other state of the Mac. Never state numbers or facts about it and never say you are checking or fixing something; if asked, say you cannot check that.",
        "If you do not know something, say so."
    ]
    let facts = loadFacts()
    if !facts.isEmpty {
        parts.append("The user asked you to remember these facts about himself and his life (use them when they help): " + facts.joined(separator: "; ") + ".")
    }
    return parts.joined(separator: " ")
}

// MARK: - Voice commands (BRO handles these itself; they never go to the AI)


enum VoiceCommand {
    case shutdown
    case openApp(String)
    case closeApp(String)
    case time
    case date
    case weather(String?)         // nil = the home city
    case say(String)              // just speak this text
    case volumeSet(Int)
    case volumeChange(Int)
    case volumeMute(Bool)
    case volumeAsk
    case media(Int)               // 16 = play/pause, 17 = next, 18 = previous
    case search(String, Bool)     // (what to look for, true = YouTube)
    case playRandomSong
    case playAllSongs
    case stopMusic
    case closeSong                // ends the song for good (a later "play" does not resume it)
    case brightnessChange(Int)    // steps: + brighter, - dimmer
    case brightnessSet(Int)       // percent
    case calendarToday
    case runShortcut(String)      // a Shortcut from the Shortcuts app, by name
    case openFolder(String)       // full path
    case wifiPower(Bool)
    case playLocalSong(String)    // only the MP3 files in ~/Music/songs
    case playAnySong(String)      // MP3 in ~/Music/songs first, then YouTube Music
    case closeYTMusic             // closes the YouTube Music app or its Brave window
    case playSong(String, Bool)   // (song, true = YouTube Music, false = YouTube) starts the first result by itself
    case timer(Int)               // seconds
    case alarm(Date)
    case cancelAlerts(String)     // "timer" or "alarm"
    case timeLeft
    case remind(String, Date)
    case note(String)
    case battery
    case wifi
    case disk
    case clipboard
    case darkMode(Int)            // 1 dark, 0 light, -1 switch
    case lockScreen
    case sleepMac
    case screenshot
    case news(String?)
    case define(String)
    case typeText(String)
    case forget
    case openIn(String, String)   // (website or thing, browser app name)
    case repeatLast
    case clipboardAI(String)         // what to do with the text on the clipboard
    case listAdd([String])
    case listRead
    case listRemove(String)
    case listClear
    case currency(Double, String, String)
    case crypto(String)
    case stopwatch(String)           // start, stop, reset, check
    case remindRepeat(String, Date, String)   // task, first time, "daily" or "weekly"
    case listAlerts(String)          // "reminder", "timer" or "alarm"
    case goTo(String)                // open a website by searching for its name
    case textBar
    case briefing
    case pageAI(String)
    case pageRead
    case writeAI(String)             // write a message / email / reply with the built-in brain, copied to the clipboard
    case factAdd(String)             // "remember that ..."
    case factsRead
    case factsClear
    case loginItem(Bool)             // start BRO when the Mac starts (true) or not (false)
    case orbColor(String)            // a colour name, or "default" for BRO's normal colours
    case keys(String)                // keyboard shortcut sent through System Events
    case pomodoro
    case speechRate(Int)             // -1 slower, 0 normal, +1 faster
    case sysInfo(String)             // "ip", "uptime" or "memory"
    case emptyTrash
    case kbLightOn                   // keyboard backlight on (last level, or full)
    case kbLightSet(Int)             // keyboard backlight to a percent (0 = off)
    case kbLightChange(Int)          // keyboard backlight up (+) or down (-) by this many percent
    case kbLightAuto                 // keyboard backlight back to automatic
    case topApps(String)             // which apps use the most "memory", "cpu" or "both"
}

// Keeps letters, digits and Hindi vowel signs (matras / halant); drops punctuation and spaces.
func normScalars(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.lowercased().unicodeScalars {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .nonspacingMark, .spacingMark:
            out.append(u)
        default:
            break
        }
    }
    return String(out)
}

func commandWords(_ text: String) -> [String] {
    text.components(separatedBy: .whitespacesAndNewlines).map { normScalars($0) }.filter { !$0.isEmpty }
}

let openVerbs: Set<String> = ["open", "launch", "kholo", "khol", "kholiye", "kholna",
                              "खोलो", "खोल", "खोलिए", "खोलिये", "खोलना"]
let fillerWords: Set<String> = ["bro", "ब्रो", "hey", "hi", "please", "plz", "pls", "can", "could", "you", "the",
                                "app", "application", "apps", "for", "me", "karo", "kar", "kardo", "do", "de", "dena",
                                "ko", "ek", "zara", "jara", "ji", "na", "to", "एप", "ऐप", "दो", "दे", "करो", "कर",
                                "को", "ज़रा", "जरा", "जी", "तो", "आप"]
let closeVerbs: Set<String> = ["close", "quit", "band", "बंद", "बन्द"]
let closeFillers: Set<String> = ["ho", "jao", "jaao", "ja", "jaa", "हो", "जाओ", "जा"]
let macWords: Set<String> = ["mac", "macbook", "computer", "laptop", "pc", "system", "कंप्यूटर", "मैक"]

// MARK: - Understanding numbers, times and sums

let numberWords: [String: Int] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
    "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90
]

func numberValue(_ t: String) -> Int? {
    if let n = Int(t) { return n }
    return numberWords[t]
}

// Splits "5pm" into "5" and "pm". ("7:30" has already become "730" and stays one number.)
func timeTokens(_ w: [String]) -> [String] {
    var out: [String] = []
    for t in w {
        if t.hasSuffix("am") || t.hasSuffix("pm") {
            let head = String(t.dropLast(2))
            if !head.isEmpty && head.allSatisfy({ $0.isNumber }) {
                out.append(head)
                out.append(String(t.suffix(2)))
                continue
            }
        }
        out.append(t)
    }
    return out
}

func unitSeconds(_ t: String) -> Int? {
    switch t {
    case "second", "seconds", "sec", "secs": return 1
    case "minute", "minutes", "min", "mins": return 60
    case "hour", "hours", "hr", "hrs": return 3600
    default: return nil
    }
}

// Finds "10 minutes", "an hour", "half an hour", "1 hour 30 minutes". Returns the seconds and where it sits.
func parseDuration(_ t: [String]) -> (seconds: Int, start: Int, end: Int)? {
    var total = 0.0
    var start = -1
    var end = -1
    for i in 0..<t.count {
        guard i >= 1, let unit = unitSeconds(t[i]) else { continue }
        var amount: Double? = nil
        var first = i - 1
        if let n = numberValue(t[i - 1]) {
            amount = Double(n)
        } else if t[i - 1] == "a" || t[i - 1] == "an" {
            amount = 1
            if i >= 2 && t[i - 2] == "half" {
                amount = 0.5
                first = i - 2
            }
        } else if t[i - 1] == "half" {
            amount = 0.5
        }
        if let a = amount {
            total += a * Double(unit)
            if start < 0 { start = first }
            end = i
        }
    }
    if start < 0 || total <= 0 { return nil }
    return (seconds: Int(total), start: start, end: end)
}

// Finds a clock time such as "7 am", "5 30 pm", "at 6". ("explicit" means am or pm was said.)
func parseClock(_ t: [String]) -> (hour: Int, minute: Int, start: Int, end: Int, explicit: Bool)? {
    for i in 0..<t.count where t[i] == "am" || t[i] == "pm" {
        guard i >= 1, let n = numberValue(t[i - 1]) else { continue }
        var h = n
        var m = 0
        var start = i - 1
        if n > 100 {
            h = n / 100
            m = n % 100
        } else if i >= 2, let hh = numberValue(t[i - 2]), hh >= 1, hh <= 12, n < 60 {
            h = hh
            m = n
            start = i - 2
        }
        if h < 1 || h > 12 || m > 59 { continue }
        if t[i] == "pm" && h < 12 { h += 12 }
        if t[i] == "am" && h == 12 { h = 0 }
        if start > 0 && t[start - 1] == "at" { start -= 1 }
        return (hour: h, minute: m, start: start, end: i, explicit: true)
    }
    for i in 0..<t.count where t[i] == "at" {
        guard i + 1 < t.count, let n = numberValue(t[i + 1]) else { continue }
        var h = n
        var m = 0
        var end = i + 1
        if n > 100 {
            h = n / 100
            m = n % 100
        } else if i + 2 < t.count, let mm = numberValue(t[i + 2]), mm < 60 {
            m = mm
            end = i + 2
        }
        if h < 1 || h > 12 || m > 59 { continue }
        return (hour: h, minute: m, start: i, end: end, explicit: false)
    }
    return nil
}

// The next moment the clock shows this time.
func nextTime(hour: Int, minute: Int, explicit: Bool, tomorrow: Bool) -> Date? {
    let cal = Calendar.current
    func next(_ h: Int) -> Date? {
        cal.nextDate(after: Date(), matching: DateComponents(hour: h % 24, minute: minute, second: 0), matchingPolicy: .nextTime)
    }
    var best = next(hour)
    if !explicit && hour < 12, let alt = next(hour + 12), let b = best, alt < b { best = alt }
    if tomorrow, let b = best, cal.isDateInToday(b) { best = cal.date(byAdding: .day, value: 1, to: b) }
    return best
}

func clockText(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "h:mm a"
    return f.string(from: d)
}

func durationText(_ s: Int) -> String {
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    var parts: [String] = []
    if h > 0 { parts.append("\(h) hour" + (h == 1 ? "" : "s")) }
    if m > 0 { parts.append("\(m) minute" + (m == 1 ? "" : "s")) }
    if sec > 0 && h == 0 { parts.append("\(sec) second" + (sec == 1 ? "" : "s")) }
    return parts.isEmpty ? "0 seconds" : parts.joined(separator: " and ")
}

func parseReminder(_ t: [String]) -> VoiceCommand {
    var when: Date? = nil
    var cut: (Int, Int)? = nil
    if let d = parseDuration(t) {
        when = Date().addingTimeInterval(Double(d.seconds))
        var s = d.start
        if s > 0 && t[s - 1] == "in" { s -= 1 }
        cut = (s, d.end)
    } else if let c = parseClock(t) {
        when = nextTime(hour: c.hour, minute: c.minute, explicit: c.explicit, tomorrow: t.contains("tomorrow"))
        cut = (c.start, c.end)
    }
    guard let date = when, let range = cut else {
        return .say("When should I remind you? Say for example: remind me to call mom at 5 PM.")
    }
    var rest: [String] = []
    for (i, tok) in t.enumerated() where i < range.0 || i > range.1 {
        rest.append(tok)
    }
    let lead: Set<String> = ["remind", "me", "bro", "please", "can", "you", "could", "hey", "to", "about",
                             "that", "a", "reminder", "tomorrow"]
    let tail: Set<String> = ["to", "in", "at", "on", "for", "tomorrow", "please"]
    while let f = rest.first, lead.contains(f) { rest.removeFirst() }
    while let l = rest.last, tail.contains(l) { rest.removeLast() }
    let task = rest.isEmpty ? "something" : rest.joined(separator: " ")
    return .remind(task, date)
}

// MARK: - Calculator (spoken sums, worked out by BRO itself so the answer is always right)

struct MiniCalc {
    var tokens: [String]
    var pos = 0
    var failed = false

    init(_ t: [String]) { tokens = t }

    func peek() -> String? { pos < tokens.count ? tokens[pos] : nil }

    mutating func expr() -> Double {
        var v = term()
        while let t = peek(), t == "+" || t == "-" {
            pos += 1
            let r = term()
            v = (t == "+") ? v + r : v - r
        }
        return v
    }

    mutating func term() -> Double {
        var v = factor()
        while let t = peek(), t == "*" || t == "/" {
            pos += 1
            let r = factor()
            if t == "/" {
                if r == 0 {
                    failed = true
                    return 0
                }
                v /= r
            } else {
                v *= r
            }
        }
        return v
    }

    mutating func factor() -> Double {
        guard let t = peek() else {
            failed = true
            return 0
        }
        pos += 1
        if t == "-" { return -factor() }
        if t == "(" {
            let v = expr()
            if peek() == ")" { pos += 1 } else { failed = true }
            return v
        }
        if let d = Double(t) { return d }
        failed = true
        return 0
    }
}

func formatNumber(_ v: Double) -> String {
    if v == v.rounded() && abs(v) < 1e12 { return String(Int(v)) }
    var s = String(format: "%.4f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

func calcAnswer(_ text: String) -> String? {
    var s = " " + text.lowercased() + " "
    for p in ["what's", "what’s", "whats", "what is", "calculate", "compute", "how much is", "equals",
              "equal to", "please", "tell me", "bro"] {
        s = s.replacingOccurrences(of: p, with: " ")
    }
    s = s.replacingOccurrences(of: "?", with: " ").replacingOccurrences(of: "=", with: " ")
    s = s.replacingOccurrences(of: ",", with: "")

    // square root of 144
    if let r = s.range(of: "square root of ") {
        let rest = s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let n = Double(rest), n >= 0 {
            return "The square root of \(formatNumber(n)) is \(formatNumber(n.squareRoot()))."
        }
    }

    let num = "(\\d+(?:\\.\\d+)?)"
    s = s.replacingOccurrences(of: num + "\\s*(?:percent|%)\\s*of\\s*" + num, with: "($1 / 100 * $2)", options: .regularExpression)
    s = s.replacingOccurrences(of: num + "\\s*squared", with: "($1 * $1)", options: .regularExpression)
    s = s.replacingOccurrences(of: "(\\d)\\s*x\\s*(\\d)", with: "$1 * $2", options: .regularExpression)
    for (word, op) in [(" plus ", " + "), (" minus ", " - "), (" times ", " * "), (" multiplied by ", " * "),
                       (" divided by ", " / "), (" over ", " / "), ("×", " * "), ("÷", " / ")] {
        s = s.replacingOccurrences(of: word, with: op)
    }
    var converted: [String] = []
    for piece in s.split(separator: " ") {
        let p = String(piece)
        if let n = numberWords[p] { converted.append(String(n)) } else { converted.append(p) }
    }
    s = converted.joined(separator: " ")

    var tokens: [String] = []
    var cur = ""
    for ch in s {
        if ch.isNumber || ch == "." {
            cur.append(ch)
        } else {
            if !cur.isEmpty { tokens.append(cur); cur = "" }
            if "+-*/()".contains(ch) {
                tokens.append(String(ch))
            } else if ch == " " {
                continue
            } else {
                return nil
            }
        }
    }
    if !cur.isEmpty { tokens.append(cur) }

    let numbers = tokens.filter { Double($0) != nil }.count
    let hasOp = tokens.contains { $0 == "+" || $0 == "-" || $0 == "*" || $0 == "/" }
    if numbers < 2 || !hasOp { return nil }
    var calc = MiniCalc(tokens)
    let v = calc.expr()
    if calc.failed || calc.pos != tokens.count { return nil }
    return "The answer is \(formatNumber(v))."
}

// MARK: - Websites BRO can open by name

let siteAliases: [String: [String]] = [
    "youtube": ["YouTube", "https://www.youtube.com"],
    "google": ["Google", "https://www.google.com"],
    "gmail": ["Gmail", "https://mail.google.com"],
    "github": ["GitHub", "https://github.com"],
    "chatgpt": ["ChatGPT", "https://chatgpt.com"],
    "claude": ["Claude", "https://claude.ai"],
    "instagram": ["Instagram", "https://www.instagram.com"],
    "facebook": ["Facebook", "https://www.facebook.com"],
    "twitter": ["Twitter", "https://x.com"],
    "linkedin": ["LinkedIn", "https://www.linkedin.com"],
    "netflix": ["Netflix", "https://www.netflix.com"],
    "amazon": ["Amazon", "https://www.amazon.in"],
    "flipkart": ["Flipkart", "https://www.flipkart.com"],
    "wikipedia": ["Wikipedia", "https://www.wikipedia.org"],
    "reddit": ["Reddit", "https://www.reddit.com"],
    "whatsappweb": ["WhatsApp Web", "https://web.whatsapp.com"],
    "drive": ["Google Drive", "https://drive.google.com"],
    "youtubemusic": ["YouTube Music", "https://music.youtube.com"],
    "ytmusic": ["YouTube Music", "https://music.youtube.com"]
]

// MARK: - Running tools on the Mac

// MARK: - Exact screen brightness (built-in display). Falls back to the brightness keys if this is not available.

private let displayServicesHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

func getScreenBrightness() -> Float? {
    guard let h = displayServicesHandle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    let fn = unsafeBitCast(sym, to: GetFn.self)
    var value: Float = 0
    return fn(CGMainDisplayID(), &value) == 0 ? value : nil
}

func setScreenBrightness(_ v: Float) -> Bool {
    guard let h = displayServicesHandle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return false }
    typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    let fn = unsafeBitCast(sym, to: SetFn.self)
    return fn(CGMainDisplayID(), max(0, min(1, v))) == 0
}

// "fifty", "twenty five", "one hundred", "75"
func spokenNumber(_ w: [String]) -> Int? {
    if w.contains("hundred") { return 100 }
    var i = 0
    while i < w.count {
        if let n = Int(w[i]) { return n }
        if let n = numberWords[w[i]] {
            if n >= 20 && n % 10 == 0, i + 1 < w.count, let o = numberWords[w[i + 1]], o >= 1, o <= 9 { return n + o }
            return n
        }
        i += 1
    }
    return nil
}

// MARK: - More helpers (v29): units, dates, random things, lists, wikipedia, chat bar

let weekdayNames: [String: Int] = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                                   "thursday": 5, "friday": 6, "saturday": 7]
let monthNames: [String: Int] = ["january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
                                 "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
                                 "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
                                 "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12]

let browserNames: [String: String] = ["brave": "Brave Browser", "chrome": "Google Chrome", "googlechrome": "Google Chrome",
                                      "safari": "Safari", "firefox": "Firefox", "edge": "Microsoft Edge",
                                      "microsoftedge": "Microsoft Edge", "arc": "Arc"]

struct UnitInfo {
    let cat: String
    let f: Double
    let name: String
}

let unitTable: [String: UnitInfo] = {
    var t: [String: UnitInfo] = [:]
    func add(_ keys: [String], _ cat: String, _ f: Double, _ name: String) {
        for k in keys { t[k] = UnitInfo(cat: cat, f: f, name: name) }
    }
    add(["km", "kms", "kilometer", "kilometers", "kilometre", "kilometres"], "len", 1000, "kilometers")
    add(["m", "meter", "meters", "metre", "metres"], "len", 1, "meters")
    add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], "len", 0.01, "centimeters")
    add(["mm", "millimeter", "millimeters"], "len", 0.001, "millimeters")
    add(["mile", "miles"], "len", 1609.344, "miles")
    add(["foot", "feet", "ft"], "len", 0.3048, "feet")
    add(["inch", "inches"], "len", 0.0254, "inches")
    add(["yard", "yards"], "len", 0.9144, "yards")
    add(["kg", "kgs", "kilogram", "kilograms", "kilo", "kilos"], "wt", 1, "kilograms")
    add(["g", "gram", "grams"], "wt", 0.001, "grams")
    add(["pound", "pounds", "lb", "lbs"], "wt", 0.45359237, "pounds")
    add(["ounce", "ounces", "oz"], "wt", 0.0283495, "ounces")
    add(["liter", "liters", "litre", "litres", "l"], "vol", 1, "liters")
    add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], "vol", 0.001, "milliliters")
    add(["gallon", "gallons"], "vol", 3.78541, "gallons")
    add(["kmh", "kph"], "spd", 1, "kilometers per hour")
    add(["mph"], "spd", 1.609344, "miles per hour")
    add(["celsius", "centigrade"], "temp", 1, "degrees Celsius")
    add(["fahrenheit"], "temp", 2, "degrees Fahrenheit")
    add(["kelvin"], "temp", 3, "kelvin")
    add(["usd", "dollar", "dollars"], "cur", 0, "USD")
    add(["inr", "rupee", "rupees"], "cur", 0, "INR")
    add(["eur", "euro", "euros"], "cur", 0, "EUR")
    add(["gbp"], "cur", 0, "GBP")
    add(["jpy", "yen"], "cur", 0, "JPY")
    add(["aed", "dirham", "dirhams"], "cur", 0, "AED")
    add(["cad"], "cur", 0, "CAD")
    add(["aud"], "cur", 0, "AUD")
    add(["sgd"], "cur", 0, "SGD")
    add(["cny", "yuan"], "cur", 0, "CNY")
    return t
}()

let currencyNames: [String: String] = ["USD": "US dollars", "INR": "Indian rupees", "EUR": "euros", "GBP": "British pounds",
                                       "JPY": "Japanese yen", "AED": "UAE dirhams", "CAD": "Canadian dollars",
                                       "AUD": "Australian dollars", "SGD": "Singapore dollars", "CNY": "Chinese yuan"]

func formatShort(_ v: Double) -> String {
    if v == v.rounded() && abs(v) < 1e12 { return String(Int(v)) }
    var s = String(format: "%.2f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

func formatBig(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = v < 100 ? 2 : 0
    return f.string(from: NSNumber(value: v)) ?? formatShort(v)
}

// "convert 5 km to miles", "50 dollars in rupees", "how many miles in 10 km"
func parseConversion(_ text: String, _ w: [String]) -> VoiceCommand? {
    if w.count > 9 || w.count < 3 { return nil }
    let lower = text.lowercased()
    var amount: Double? = nil
    if let r = lower.range(of: "\\d+(?:\\.\\d+)?", options: .regularExpression) {
        amount = Double(lower[r])
    } else if let n = spokenNumber(w) {
        amount = Double(n)
    }
    guard let value = amount else { return nil }
    var found: [String] = []
    for tok in w where unitTable[tok] != nil { found.append(tok) }
    if found.count < 2 { return nil }
    var from = found[0]
    var to = found[1]
    if w.first == "how" && w.count > 1 && w[1] == "many" {
        from = found[1]
        to = found[0]
    }
    guard var a = unitTable[from], var b = unitTable[to] else { return nil }
    if a.cat != b.cat {
        // "pounds" can also be the British currency
        if a.cat == "wt" && a.name == "pounds" && b.cat == "cur" { a = UnitInfo(cat: "cur", f: 0, name: "GBP") }
        else if b.cat == "wt" && b.name == "pounds" && a.cat == "cur" { b = UnitInfo(cat: "cur", f: 0, name: "GBP") }
        else { return nil }
    }
    if a.cat == "cur" { return .currency(value, a.name, b.name) }
    var result = 0.0
    if a.cat == "temp" {
        var c = value                      // go through Celsius
        if a.f == 2 { c = (value - 32) * 5 / 9 }
        if a.f == 3 { c = value - 273.15 }
        if b.f == 1 { result = c }
        if b.f == 2 { result = c * 9 / 5 + 32 }
        if b.f == 3 { result = c + 273.15 }
    } else {
        result = value * a.f / b.f
    }
    return .say("\(formatShort(value)) \(a.name) is \(formatShort(result)) \(b.name).")
}

func fetchCurrency(_ value: Double, _ from: String, _ to: String) async -> String {
    guard let url = URL(string: "https://open.er-api.com/v6/latest/\(from)") else { return "I could not convert that." }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rates = obj["rates"] as? [String: Any],
           let rate = rates[to] as? Double {
            let a = currencyNames[from] ?? from
            let b = currencyNames[to] ?? to
            return "\(formatBig(value)) \(a) is about \(formatBig(value * rate)) \(b)."
        }
        return "I could not find the exchange rate."
    } catch {
        return "I could not get the exchange rate. Please check your internet connection."
    }
}

func fetchCrypto(_ coin: String) async -> String {
    guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(coin)&vs_currencies=inr,usd") else {
        return "I could not get that price."
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let c = obj[coin] as? [String: Any],
           let inr = c["inr"] as? Double, let usd = c["usd"] as? Double {
            return "\(coin.capitalized) is about \(formatBig(inr)) rupees, or \(formatBig(usd)) US dollars."
        }
        return "I could not find that price right now."
    } catch {
        return "I could not get the price. Please check your internet connection."
    }
}

// "how many days until Christmas", "days till 15 August"
func daysUntilAnswer(_ w: [String]) -> String? {
    let joined = w.joined(separator: " ")
    guard joined.contains("days") else { return nil }
    guard let kw = w.firstIndex(where: { $0 == "until" || $0 == "till" || $0 == "to" || $0 == "before" }),
          kw + 1 < w.count else { return nil }
    let rest = Array(w[(kw + 1)...])
    let restJoined = rest.joined(separator: " ")
    var month: Int? = nil
    var day: Int? = nil
    var year: Int? = nil
    var label = ""
    if restJoined.contains("christmas") { month = 12; day = 25; label = "Christmas" }
    else if restJoined.contains("new year") || restJoined.contains("newyear") { month = 1; day = 1; label = "New Year" }
    else if restJoined.contains("republic") { month = 1; day = 26; label = "Republic Day" }
    else if restJoined.contains("independence") { month = 8; day = 15; label = "Independence Day" }
    else if restJoined.contains("valentine") { month = 2; day = 14; label = "Valentine's Day" }
    else if restJoined.contains("halloween") { month = 10; day = 31; label = "Halloween" }
    for tok in rest {
        if let m = monthNames[tok], month == nil { month = m }
        var s = tok
        if s.count > 2 && (s.hasSuffix("st") || s.hasSuffix("nd") || s.hasSuffix("rd") || s.hasSuffix("th")) {
            s = String(s.dropLast(2))
        }
        if let n = Int(s) {
            if n >= 2025 && n <= 2100 { year = n } else if n >= 1 && n <= 31 && day == nil { day = n }
        }
    }
    guard let m = month, let d = day else { return nil }
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    var comps = DateComponents()
    comps.month = m
    comps.day = d
    comps.year = year ?? cal.component(.year, from: today)
    guard var target = cal.date(from: comps) else { return nil }
    if year == nil && target < today {
        comps.year = (comps.year ?? 0) + 1
        target = cal.date(from: comps) ?? target
    }
    if label.isEmpty {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMMM"
        label = f.string(from: target)
    }
    let n = cal.dateComponents([.day], from: today, to: target).day ?? 0
    if n == 0 { return "\(label) is today!" }
    if n == 1 { return "\(label) is tomorrow." }
    return "There are \(n) days until \(label)."
}

// Coin, dice and random numbers
func randomAnswer(_ w: [String]) -> String? {
    let joined = w.joined(separator: " ")
    if w.count <= 6 && (joined.contains("flip a coin") || joined.contains("toss a coin") || joined.contains("heads or tails")
                        || joined.contains("flip coin") || joined.contains("toss coin")) {
        return Bool.random() ? "Heads." : "Tails."
    }
    if w.count <= 7 && (w.contains("dice") || w.contains("die")) && (w.contains("roll") || w.contains("throw")) {
        var count = 1
        if let i = w.firstIndex(where: { $0 == "dice" || $0 == "die" }), i >= 1,
           let n = numberValue(w[i - 1]), n >= 1, n <= 6 {
            count = n
        }
        var rolls: [Int] = []
        for _ in 0..<count { rolls.append(Int.random(in: 1...6)) }
        if count == 1 { return "You rolled a \(rolls[0])." }
        let total = rolls.reduce(0, +)
        return "You rolled " + rolls.map { String($0) }.joined(separator: ", ") + ". Total \(total)."
    }
    if joined.contains("random number") || joined.contains("pick a number") || joined.contains("number between") {
        let nums = w.compactMap { numberValue($0) }
        if nums.count >= 2 {
            let lo = min(nums[0], nums[1])
            let hi = max(nums[0], nums[1])
            return "\(Int.random(in: lo...hi))."
        }
        return "\(Int.random(in: 1...100))."
    }
    return nil
}

// Shopping list: "add milk and eggs to my list", "what is on my list", "remove milk from my list", "clear my list"
func parseList(_ w: [String]) -> VoiceCommand? {
    guard w.count <= 14, w.contains("list") else { return nil }
    let wset = Set(w)
    let joined = w.joined(separator: " ")
    let first = w.first ?? ""
    let noise: Set<String> = ["a", "an", "the", "some", "my", "our", "bro", "please", "shopping", "grocery", "todo"]
    func items(_ ws: ArraySlice<String>) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        for x in ws {
            if x == "and" {
                if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
                cur = []
            } else if !noise.contains(x) {
                cur.append(x)
            }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
        return out
    }
    if first == "add" || first == "put" {
        if let p = w.lastIndex(where: { $0 == "to" || $0 == "on" || $0 == "in" || $0 == "into" }), p > 1 {
            let its = items(w[1..<p])
            if !its.isEmpty { return .listAdd(its) }
        }
        return nil
    }
    if first == "remove" || first == "delete" || first == "cross" || first == "take" {
        if let p = w.lastIndex(where: { $0 == "from" || $0 == "off" || $0 == "on" }), p > 1 {
            let its = items(w[1..<p])
            if !its.isEmpty { return .listRemove(its.joined(separator: " ")) }
        }
    }
    if first == "clear" || first == "empty" || first == "erase" || first == "reset" || first == "delete" || first == "wipe" {
        return .listClear
    }
    let readFirst: Set<String> = ["read", "what", "whats", "show", "tell", "check", "list"]
    let mine = wset.contains("my") || wset.contains("shopping") || wset.contains("grocery") || wset.contains("todo")
        || joined.contains("on the list")
    if readFirst.contains(first) && mine { return .listRead }
    return nil
}

// "remind me every day at 9 am to take medicine", "remind me every monday at 8 am to go to the gym"
func parseRecurringReminder(_ t: [String]) -> VoiceCommand? {
    var rule = ""
    var weekday = 0
    var cut: (Int, Int)? = nil
    if let e = t.firstIndex(of: "every"), e + 1 < t.count {
        let nxt = t[e + 1]
        if nxt == "day" || nxt == "morning" || nxt == "evening" || nxt == "night" {
            rule = "daily"
            cut = (e, e + 1)
        } else if let wd = weekdayNames[nxt] {
            rule = "weekly"
            weekday = wd
            cut = (e, e + 1)
        }
    } else if let d = t.firstIndex(where: { $0 == "daily" || $0 == "everyday" }) {
        rule = "daily"
        cut = (d, d)
    }
    guard !rule.isEmpty, let everyCut = cut else { return nil }
    guard let c = parseClock(t) else {
        return .say("What time? Say for example: remind me every day at 9 AM to take medicine.")
    }
    var first: Date? = nil
    if rule == "daily" {
        first = nextTime(hour: c.hour, minute: c.minute, explicit: c.explicit, tomorrow: false)
    } else {
        var dc = DateComponents()
        dc.hour = c.hour
        dc.minute = c.minute
        dc.second = 0
        dc.weekday = weekday
        first = Calendar.current.nextDate(after: Date(), matching: dc, matchingPolicy: .nextTime)
    }
    guard let when = first else { return nil }
    var rest: [String] = []
    for (i, tok) in t.enumerated() {
        let inEvery = i >= everyCut.0 && i <= everyCut.1
        let inClock = i >= c.start && i <= c.end
        if !inEvery && !inClock { rest.append(tok) }
    }
    let lead: Set<String> = ["remind", "me", "bro", "please", "can", "you", "could", "hey", "to", "about", "that", "a", "reminder"]
    let tail: Set<String> = ["to", "in", "at", "on", "for", "please"]
    while let f = rest.first, lead.contains(f) { rest.removeFirst() }
    while let l = rest.last, tail.contains(l) { rest.removeLast() }
    let task = rest.isEmpty ? "something" : rest.joined(separator: " ")
    return .remindRepeat(task, when, rule)
}

// Everything that is new in v29, tried before the older rules.
func parseExtras(_ text: String, _ w: [String]) -> VoiceCommand? {
    let wset = Set(w)
    let joined = w.joined(separator: " ")
    let t = timeTokens(w)

    if let more = parseMore(text, w) { return more }

    // orb colour: "make the orb red", "change orb colour to green", "default colour"
    do {
        if (wset.contains("colour") || wset.contains("color") || wset.contains("orb")) && w.count <= 10 {
            if !wset.isDisjoint(with: ["default", "normal", "original", "reset", "usual"]) { return .orbColor("default") }
            for x in w {
                let name = orbColorAliases[x] ?? x
                if orbColorChoices[name] != nil { return .orbColor(name) }
            }
        }
    }

    // start BRO when the Mac starts
    do {
        let atLogin = joined.contains("at login") || joined.contains("at startup") || joined.contains("on startup")
            || joined.contains("when mac starts") || joined.contains("when my mac starts") || joined.contains("when i log in")
            || joined.contains("when i login") || joined.contains("start automatically") || joined.contains("launch at login")
        if atLogin && w.count <= 12 {
            let offWords: Set<String> = ["stop", "dont", "disable", "off", "remove", "never", "not", "no"]
            return .loginItem(wset.isDisjoint(with: offWords))
        }
    }

    // memory of facts: "remember that my car key is in the drawer", "what do you remember", "forget your memories"
    do {
        var ww = w
        let lead: Set<String> = ["bro", "please", "can", "could", "would", "you", "hey", "just", "kindly", "ok", "okay"]
        while let f = ww.first, lead.contains(f) { ww.removeFirst() }
        if ww.first == "remember" && ww.count >= 3 {
            var rest = Array(ww.dropFirst())
            if rest.first == "that" { rest.removeFirst() }
            if rest.count >= 2 { return .factAdd(rest.joined(separator: " ")) }
        }
        if (joined.contains("what do you remember") || joined.contains("what did i tell you") || joined.contains("what do you know about me")
            || joined.contains("what have i told you")) && w.count <= 9 {
            return .factsRead
        }
        if wset.contains("forget") && !wset.isDisjoint(with: ["memory", "memories", "facts", "remembered", "everything"]) && w.count <= 8 {
            return .factsClear
        }
    }

    // write a message / email / reply with the brain
    do {
        var ww = w
        let lead: Set<String> = ["bro", "please", "can", "could", "would", "you", "hey", "just", "kindly", "ok", "okay"]
        while let f = ww.first, lead.contains(f) { ww.removeFirst() }
        let writeVerbs: Set<String> = ["write", "draft", "compose"]
        let writeNouns: Set<String> = ["message", "email", "mail", "text", "reply", "letter", "apology", "excuse", "request", "application", "caption", "msg"]
        if let f = ww.first, writeVerbs.contains(f), ww.count >= 4, !wset.isDisjoint(with: writeNouns), !wset.contains("clipboard") {
            return .writeAI(text)
        }
    }

    // morning briefing
    if w.count <= 5 && (joined.contains("good morning") || joined.contains("morning briefing") || joined.contains("daily briefing")
                        || joined.contains("brief me") || joined.contains("my briefing") || joined.contains("start my day")
                        || joined.contains("whats my day") || joined.contains("what is my day")) {
        return .briefing
    }
    // the page open in the browser: "summarize this page", "what is this page about", "read this page"
    let pageNouns: Set<String> = ["page", "article", "tab", "website", "site"]
    let pageVerbs: Set<String> = ["summarize", "summarise", "summary", "summerize", "samarize", "sumarize", "summarized", "summarizing", "explain", "tldr", "read", "about"]
    if w.count <= 9 && !wset.isDisjoint(with: pageNouns) && !wset.isDisjoint(with: pageVerbs)
        && (wset.contains("this") || wset.contains("current") || wset.contains("open")) {
        if wset.contains("read") && !wset.contains("summarize") && !wset.contains("summarise") { return .pageRead }
        if wset.contains("explain") || wset.contains("about") {
            return .pageAI("Explain what this web page is about in simple words, in three short sentences")
        }
        return .pageAI("Summarize this web page in three short sentences")
    }

    // "repeat that", "say that again"
    if w.count <= 5 && !wset.contains("play") && !wset.contains("song") && !wset.contains("music")
        && (wset.contains("repeat") || joined.contains("say that again") || joined.contains("say it again")
            || joined.contains("what did you say") || joined.contains("come again")) {
        return .repeatLast
    }
    // the typing window
    if w.count <= 5 && (joined.contains("text bar") || joined.contains("text mode") || joined.contains("typing mode")
                        || joined.contains("chat window") || joined.contains("type mode") || joined.contains("keyboard mode")) {
        return .textBar
    }
    // stopwatch
    if wset.contains("stopwatch") && w.count <= 6 {
        if wset.contains("start") || wset.contains("begin") { return .stopwatch("start") }
        if wset.contains("stop") || wset.contains("end") || wset.contains("finish") { return .stopwatch("stop") }
        if wset.contains("reset") || wset.contains("clear") { return .stopwatch("reset") }
        return .stopwatch("check")
    }
    if let r = randomAnswer(w) { return .say(r) }
    if let d = daysUntilAnswer(w) { return .say(d) }
    if let l = parseList(w) { return l }

    // clipboard + AI
    if wset.contains("clipboard") {
        var instr: String? = nil
        if wset.contains("summarize") || wset.contains("summarise") || wset.contains("summary") {
            instr = "Summarize this text in two short sentences"
        } else if wset.contains("explain") {
            instr = "Explain this text in simple words, in two or three sentences"
        } else if wset.contains("fix") || wset.contains("proofread") || wset.contains("correct") {
            instr = "Fix the spelling and grammar of this text and reply with only the corrected text"
        } else if wset.contains("shorten") || wset.contains("shorter") {
            instr = "Make this text shorter and reply with only the shorter text"
        } else if wset.contains("translate") {
            instr = "Translate this text into simple English and reply with only the translation"
        } else if wset.contains("reply") || wset.contains("respond") || wset.contains("answer") {
            instr = "Write a short, polite reply to this message and reply with only the reply text"
        } else if wset.contains("rewrite") || wset.contains("polite") || wset.contains("professional") || wset.contains("formal") {
            instr = "Rewrite this text in a polite, professional tone and reply with only the rewritten text"
        }
        if let i = instr { return .clipboardAI(i) }
    }

    // reminders that repeat, and looking at or cancelling reminders
    if wset.contains("remind") && (wset.contains("every") || wset.contains("daily") || wset.contains("everyday")) {
        if let r = parseRecurringReminder(t) { return r }
    }
    let stopWords2: Set<String> = ["cancel", "cancelled", "canceled", "cancelling", "canceling", "stop", "stopped", "delete", "remove", "clear", "off"]
    if (wset.contains("reminders") || wset.contains("reminder")) && !wset.contains("remind") {
        if !wset.isDisjoint(with: stopWords2) { return .cancelAlerts("reminder") }
        if !wset.isDisjoint(with: ["what", "whats", "list", "show", "read", "tell", "any", "my"]) { return .listAlerts("reminder") }
    }
    if wset.contains("timers") && !wset.isDisjoint(with: ["what", "whats", "list", "show", "any"]) { return .listAlerts("timer") }
    if wset.contains("alarms") && !wset.isDisjoint(with: ["what", "whats", "list", "show", "any"]) { return .listAlerts("alarm") }

    // crypto prices
    let coins: [String: String] = ["bitcoin": "bitcoin", "btc": "bitcoin", "ethereum": "ethereum", "eth": "ethereum",
                                   "dogecoin": "dogecoin", "solana": "solana"]
    if let c = w.first(where: { coins[$0] != nil }),
       !wset.isDisjoint(with: ["price", "worth", "rate", "cost", "much"]) {
        return .crypto(coins[c] ?? c)
    }

    if let c = parseConversion(text, w) { return c }

    // "go to flipkart", "visit amazon", "open the nptel website"
    let blocked: Set<String> = ["sleep", "bed", "next", "previous", "back", "home", "work", "school", "college", "the", "my"]
    if w.count >= 3 && w.count <= 7 && ((w[0] == "go" && w[1] == "to") || w[0] == "visit" || w[0] == "browse") {
        let skip: Set<String> = ["go", "to", "visit", "browse", "the", "website", "site", "page", "please", "bro", "my", "web"]
        let name = w.filter { !skip.contains($0) }
        if let f = name.first, !blocked.contains(f), name.count <= 4, !name.isEmpty {
            return .goTo(name.joined(separator: " "))
        }
    }
    if w.first == "open" && (wset.contains("website") || wset.contains("site")) && w.count <= 7 {
        let skip: Set<String> = ["open", "the", "website", "site", "page", "please", "bro", "my", "web", "in", "inside", "brave", "browser", "chrome", "safari"]
        let name = w.filter { !skip.contains($0) }
        if !name.isEmpty && name.count <= 4 { return .goTo(name.joined(separator: " ")) }
    }
    return nil
}

// "open brave and search lofi" becomes two commands. Used only when EVERY part is a command BRO knows.
func parseChain(_ text: String) -> [VoiceCommand]? {
    var s = " " + text.lowercased() + " "
    let hasSep = s.contains(" and ") || s.contains(" then ")
    s = s.replacingOccurrences(of: "\\s+(?:and then|and also|then|and|after that)\\s+", with: "|", options: .regularExpression)
    if !hasSep {
        // no "and" said: "brightness 40 open safari" is cut in front of the second action word
        let cw = commandWords(text)
        let swallow: Set<String> = ["play", "search", "lookup", "look", "type", "note", "remind", "define", "what", "whats", "who", "why",
                                    "how", "tell", "write", "draft", "compose", "remember", "explain", "where", "when"]
        if cw.count > 9 || cw.isEmpty || swallow.contains(cw[0]) { return nil }
        s = s.replacingOccurrences(of: "\\s+(?=(?:open|close|launch|play|search)\\s)", with: "|", options: .regularExpression)
        // v56: "brightness 40, backlit 1": keyboard light + screen brightness/volume, cut in front of the second one
        let kbMarkers: Set<String> = ["keyboard", "backlit", "backlight"]
        if let mi = cw.firstIndex(where: { kbMarkers.contains($0) }),
           let oi = cw.firstIndex(where: { $0 == "brightness" || $0 == "volume" }) {
            let later = mi > oi ? cw[mi] : cw[oi]
            s = s.replacingOccurrences(of: "\\s+(?=\(later)\\b)", with: "|", options: .regularExpression)
        }
        // v55: "volume 30 brightness 50": cut in front of whichever of the two words comes second
        if let vi = cw.firstIndex(of: "volume"), let bi = cw.firstIndex(of: "brightness") {
            let later = vi > bi ? "volume" : "brightness"
            s = s.replacingOccurrences(of: "\\s+(?=\(later)\\b)", with: "|", options: .regularExpression)
        }
    }
    let parts = s.split(separator: "|").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " ,.")) }.filter { !$0.isEmpty }
    guard parts.count >= 2 && parts.count <= 4 else { return nil }
    var cmds: [VoiceCommand] = []
    for p in parts {
        guard let c = parseCommand(p) else { return nil }
        cmds.append(c)
    }
    return cmds
}

// MARK: - Wikipedia answers (online); offline BRO falls back to the AI

func wikiTopic(_ text: String) -> String? {
    let w = commandWords(text)
    if w.count < 3 || w.count > 9 { return nil }
    let wset = Set(w)
    let personal: Set<String> = ["you", "your", "yours", "me", "my", "i", "we", "us", "our", "bro", "yourself", "mine"]
    let opinion: Set<String> = ["best", "better", "good", "bad", "should", "worth", "recommend", "favorite", "favourite",
                                "think", "feel", "like", "prefer", "opinion", "weather", "time", "date", "temperature", "joke"]
    if !wset.isDisjoint(with: personal) || !wset.isDisjoint(with: opinion) { return nil }
    // Questions about things that change ("who is the president", "what is the latest...") are not answered from Wikipedia,
    // because an article introduction does not give the current answer.
    let changing: Set<String> = ["current", "currently", "latest", "today", "now", "recent", "newest", "new", "president", "minister",
                                 "ceo", "chairman", "captain", "coach", "winner", "champion", "richest", "price", "score", "year"]
    if !wset.isDisjoint(with: changing) { return nil }
    let starters: [[String]] = [["who", "is"], ["who", "was"], ["who", "are"], ["who", "were"], ["what", "is"],
                                ["what", "was"], ["what", "are"], ["what", "were"], ["whats"], ["tell", "about"],
                                ["tell", "me", "about"], ["where", "is"], ["where", "was"]]
    for s in starters where w.count > s.count && Array(w.prefix(s.count)) == s {
        var rest = Array(w.dropFirst(s.count))
        while let f = rest.first, f == "a" || f == "an" || f == "the" { rest.removeFirst() }
        if rest.isEmpty || rest.count > 6 { return nil }
        return rest.joined(separator: " ")
    }
    return nil
}

func fetchWikipedia(_ query: String) async -> String? {
    let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    let u = "https://en.wikipedia.org/w/api.php?action=query&generator=search&gsrsearch=\(q)&gsrlimit=1&prop=extracts&exintro=1&explaintext=1&exsentences=3&format=json&redirects=1"
    guard let url = URL(string: u) else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 6
    req.setValue("BRO/1.0 (personal voice assistant)", forHTTPHeaderField: "User-Agent")
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qd = obj["query"] as? [String: Any],
              let pages = qd["pages"] as? [String: Any],
              let page = pages.values.first as? [String: Any],
              let extract = page["extract"] as? String else { return nil }
        var text = extract.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < 20 || text.contains("may refer to") || text.contains("may also refer to") { return nil }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { s, _, _, stop in
            if let s = s { sentences.append(s.trimmingCharacters(in: .whitespaces)) }
            if sentences.count >= 2 { stop = true }
        }
        var out = sentences.joined(separator: " ")
        if out.count > 380 { out = String(out.prefix(380)) }
        return out.isEmpty ? nil : out
    } catch {
        return nil
    }
}

// MARK: - The typing window (type to BRO, BRO answers in writing AND out loud)

final class ChatModel: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let who: String
        let text: String
    }
    @Published var lines: [Line] = []
    @Published var draft = ""
    var onSend: ((String) -> Void)?

    func add(_ who: String, _ text: String) {
        lines.append(Line(who: who, text: text))
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
    }
}

final class TextPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct TextBarView: View {
    @ObservedObject var chat: ChatModel
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Type to BRO").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(chat.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.who)
                                    .font(.caption).bold()
                                    .foregroundColor(line.who == "BRO" ? .orange : .blue)
                                    .frame(width: 34, alignment: .leading)
                                Text(line.text)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                }
                .onChange(of: chat.lines.count) { _, _ in
                    if let last = chat.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            TextField("Type a message and press Return", text: $chat.draft)
                .textFieldStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
                .focused($focused)
                .onSubmit {
                    let t = chat.draft
                    chat.draft = ""
                    chat.onSend?(t)
                }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
    }
}

// MARK: - Calendar summary and reading the page open in the browser (v30)

func calendarTodaySummary() -> String? {
    let script = ["-e", "set d0 to current date", "-e", "set time of d0 to 0", "-e", "set d1 to d0 + 1 * days",
                  "-e", "set out to \"\"",
                  "-e", "tell application \"Calendar\"",
                  "-e", "repeat with c in calendars",
                  "-e", "set evs to (every event of c whose start date >= d0 and start date < d1)",
                  "-e", "repeat with e in evs",
                  "-e", "set out to out & (summary of e) & \" at \" & (time string of (start date of e)) & \";\"",
                  "-e", "end repeat",
                  "-e", "end repeat",
                  "-e", "end tell",
                  "-e", "return \"OK|\" & out"]
    let out = runTool("/usr/bin/osascript", script).trimmingCharacters(in: .whitespacesAndNewlines)
    guard out.hasPrefix("OK|") else { return nil }
    let events = out.dropFirst(3).split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if events.isEmpty { return "You have nothing on your calendar today." }
    let shown = events.prefix(5).joined(separator: ", ")
    return "You have \(events.count) \(events.count == 1 ? "event" : "events") today: \(shown)."
}

let chromiumBrowsers = ["Brave Browser", "Google Chrome", "Microsoft Edge", "Arc"]

func frontBrowserName() -> String? {
    let all = chromiumBrowsers + ["Safari"]
    if let f = NSWorkspace.shared.frontmostApplication?.localizedName, all.contains(f) { return f }
    let running = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
    return all.first(where: { running.contains($0) })
}

// Asks the browser for the title, address and text of the tab in front.
func browserPage() -> (title: String, url: String, text: String)? {
    guard let b = frontBrowserName() else { return nil }
    var url = ""
    var title = ""
    var text = ""
    if b == "Safari" {
        url = runAppleScript("tell application \"Safari\" to return URL of current tab of front window")?.stringValue ?? ""
        title = runAppleScript("tell application \"Safari\" to return name of current tab of front window")?.stringValue ?? ""
        text = runAppleScript("tell application \"Safari\" to return do JavaScript \"document.body.innerText\" in current tab of front window")?.stringValue ?? ""
    } else {
        url = runAppleScript("tell application \"\(b)\" to return URL of active tab of front window")?.stringValue ?? ""
        title = runAppleScript("tell application \"\(b)\" to return title of active tab of front window")?.stringValue ?? ""
        text = runAppleScript("tell application \"\(b)\" to return execute active tab of front window javascript \"document.body.innerText\"")?.stringValue ?? ""
    }
    return (title: title, url: url, text: text)
}

// Plain fallback for public pages: download the address and strip the tags.
func fetchPageText(_ urlString: String) async -> String? {
    guard urlString.hasPrefix("http"), let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                 forHTTPHeaderField: "User-Agent")
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        var html = String(decoding: data, as: UTF8.self)
        for pat in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<noscript[\\s\\S]*?</noscript>", "<[^>]+>"] {
            html = html.replacingOccurrences(of: pat, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let entities = [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")]
        for (e, r) in entities { html = html.replacingOccurrences(of: e, with: r) }
        html = html.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        html = html.trimmingCharacters(in: .whitespacesAndNewlines)
        return html.count > 200 ? html : nil
    } catch {
        return nil
    }
}

func readBrowserPage() async -> (title: String, text: String)? {
    guard let page = browserPage() else { return nil }
    var text = page.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count < 200, !page.url.isEmpty, let fetched = await fetchPageText(page.url) { text = fetched }
    if text.count < 100 { return nil }
    return (title: page.title, text: String(text.prefix(4000)))
}

// MARK: - v41: keyboard actions, small helpers, phone-book of new commands

let keyActions: [String: String] = [
    "new tab": "tell application \"System Events\" to keystroke \"t\" using command down",
    "open new tab": "tell application \"System Events\" to keystroke \"t\" using command down",
    "close tab": "tell application \"System Events\" to keystroke \"w\" using command down",
    "reopen tab": "tell application \"System Events\" to keystroke \"t\" using {command down, shift down}",
    "reopen closed tab": "tell application \"System Events\" to keystroke \"t\" using {command down, shift down}",
    "refresh": "tell application \"System Events\" to keystroke \"r\" using command down",
    "refresh page": "tell application \"System Events\" to keystroke \"r\" using command down",
    "reload": "tell application \"System Events\" to keystroke \"r\" using command down",
    "reload page": "tell application \"System Events\" to keystroke \"r\" using command down",
    "go back": "tell application \"System Events\" to keystroke \"[\" using command down",
    "go forward": "tell application \"System Events\" to keystroke \"]\" using command down",
    "scroll down": "tell application \"System Events\" to key code 121",
    "page down": "tell application \"System Events\" to key code 121",
    "scroll up": "tell application \"System Events\" to key code 116",
    "page up": "tell application \"System Events\" to key code 116",
    "scroll to top": "tell application \"System Events\" to key code 126 using command down",
    "scroll to bottom": "tell application \"System Events\" to key code 125 using command down",
    "zoom in": "tell application \"System Events\" to keystroke \"=\" using command down",
    "zoom out": "tell application \"System Events\" to keystroke \"-\" using command down",
    "reset zoom": "tell application \"System Events\" to keystroke \"0\" using command down",
    "copy": "tell application \"System Events\" to keystroke \"c\" using command down",
    "paste": "tell application \"System Events\" to keystroke \"v\" using command down",
    "select all": "tell application \"System Events\" to keystroke \"a\" using command down",
    "undo": "tell application \"System Events\" to keystroke \"z\" using command down",
    "redo": "tell application \"System Events\" to keystroke \"z\" using {command down, shift down}",
    "save": "tell application \"System Events\" to keystroke \"s\" using command down",
    "minimize": "tell application \"System Events\" to keystroke \"m\" using command down",
    "minimize window": "tell application \"System Events\" to keystroke \"m\" using command down",
    "hide app": "tell application \"System Events\" to keystroke \"h\" using command down",
    "full screen": "tell application \"System Events\" to keystroke \"f\" using {control down, command down}",
    "fullscreen": "tell application \"System Events\" to keystroke \"f\" using {control down, command down}",
    "exit full screen": "tell application \"System Events\" to keystroke \"f\" using {control down, command down}",
    "next desktop": "tell application \"System Events\" to key code 124 using control down",
    "next space": "tell application \"System Events\" to key code 124 using control down",
    "previous desktop": "tell application \"System Events\" to key code 123 using control down",
    "previous space": "tell application \"System Events\" to key code 123 using control down",
    "mission control": "tell application \"System Events\" to key code 126 using control down",
    "switch app": "tell application \"System Events\" to key code 48 using command down",
    "previous app": "tell application \"System Events\" to key code 48 using command down",
    "new window": "tell application \"System Events\" to keystroke \"n\" using command down",
    "press enter": "tell application \"System Events\" to key code 36",
    "enter": "tell application \"System Events\" to key code 36",
    "press escape": "tell application \"System Events\" to key code 53",
    "escape": "tell application \"System Events\" to key code 53"
]

func numbersIn(_ text: String) -> [Double] {
    guard let rx = try? NSRegularExpression(pattern: "\\d+(?:\\.\\d+)?") else { return [] }
    let ns = text.replacingOccurrences(of: ",", with: "") as NSString
    return rx.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
        .compactMap { Double(ns.substring(with: $0.range)) }
}

// MARK: - v44: keyboard backlight (private CoreBrightness, with media keys as a fallback)

private let coreBrightnessHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)

final class KeyboardLight {
    static let shared = KeyboardLight()
    private var client: NSObject?
    private var ids: [UInt64] = []

    init() {
        _ = coreBrightnessHandle
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return }
        let c = cls.init()
        client = c
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if c.responds(to: sel), let r = c.perform(sel)?.takeRetainedValue() as? [Any] {
            ids = r.compactMap { ($0 as? NSNumber)?.uint64Value }
        }
        if ids.isEmpty { ids = [1] }
    }

    func get() -> Float? {
        guard let c = client, let id = ids.first else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard c.responds(to: sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let fn = unsafeBitCast(c.method(for: sel), to: Fn.self)
        return fn(c, sel, id)
    }

    func set(_ v: Float) -> Bool {
        guard let c = client else { return false }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard c.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let fn = unsafeBitCast(c.method(for: sel), to: Fn.self)
        var ok = false
        for id in ids where fn(c, sel, max(0, min(1, v)), id) { ok = true }
        return ok
    }

    @discardableResult
    func setAuto(_ on: Bool) -> Bool {
        guard let c = client else { return false }
        let sel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        guard c.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Void
        let fn = unsafeBitCast(c.method(for: sel), to: Fn.self)
        for id in ids { fn(c, sel, on, id) }
        return true
    }
}

// True when the sentence is about the keyboard's backlight ("keyboard light off", "backlit 20", "back light up").
func mentionsKeyboardLight(_ w: [String]) -> Bool {
    let joined = w.joined(separator: " ")
    let phrases = ["backlit", "backlight", "back lit", "back light", "keyboard light", "keyboard lite", "keyboard led",
                   "keyboard illumination", "keyboard glow", "key light", "keys light", "keyboard lit"]
    if phrases.contains(where: { joined.contains($0) }) { return true }
    let wset = Set(w)
    return wset.contains("keyboard") && !wset.isDisjoint(with: ["light", "lights", "lighting", "lit", "led", "bright", "brighter",
                                                                "brightness", "dim", "dimmer", "dark", "darker", "glow", "illumination"])
}

func parseKeyboardLight(_ text: String, _ w: [String]) -> VoiceCommand? {
    guard w.count <= 9, mentionsKeyboardLight(w) else { return nil }
    if let f = w.first, ["search", "define", "type", "note", "remind", "meaning"].contains(f) { return nil }
    let wset = Set(w)
    // v50: "light up my keyboard" / "light up the keyboard" means turn ON (not "a bit brighter")
    if let li = w.firstIndex(where: { $0 == "light" || $0 == "lights" || $0 == "lit" }),
       li + 1 < w.count, w[li + 1] == "up",
       let ki = w.firstIndex(of: "keyboard"), ki > li + 1,
       wset.isDisjoint(with: ["off", "auto", "automatic", "percent", "more", "less"]),
       numbersIn(text).isEmpty {
        return .kbLightOn
    }
    if !wset.isDisjoint(with: ["auto", "automatic", "automatically"]) { return .kbLightAuto }
    if !wset.isDisjoint(with: ["off", "disable", "zero", "none", "kill", "band", "bandh"]) { return .kbLightSet(0) }
    if let n = numbersIn(text).first { return .kbLightSet(min(100, max(0, Int(n)))) }
    if let n = spokenNumber(w) { return .kbLightSet(min(100, max(0, n))) }
    if !wset.isDisjoint(with: ["max", "maximum", "full", "brightest", "highest"]) { return .kbLightSet(100) }
    if !wset.isDisjoint(with: ["min", "minimum", "lowest", "low"]) { return .kbLightSet(15) }
    let up: Set<String> = ["up", "increase", "raise", "higher", "more", "brighter", "bright", "brighten", "boost", "stronger", "zyada", "badhao", "badha"]
    let down: Set<String> = ["down", "decrease", "lower", "less", "reduce", "dimmer", "dim", "darker", "dark", "softer", "weaker", "kam", "ghatao"]
    if !wset.isDisjoint(with: up) { return .kbLightChange(15) }
    if !wset.isDisjoint(with: down) { return .kbLightChange(-15) }
    return .kbLightOn
}

// MARK: - v46: which app uses the most memory / processor

func parseTopApps(_ w: [String]) -> VoiceCommand? {
    guard w.count <= 12 else { return nil }
    let wset = Set(w)
    let mem = !wset.isDisjoint(with: ["memory", "ram"])
    let cpu = !wset.isDisjoint(with: ["cpu", "processor"])
    let appish = !wset.isDisjoint(with: ["app", "apps", "application", "applications", "program", "programs", "process", "processes"])
    let most = !wset.isDisjoint(with: ["most", "top", "highest", "hogging", "eating", "using", "uses", "taking", "heavy", "biggest"])
    let slow = !wset.isDisjoint(with: ["slow", "lag", "laggy", "lagging", "hang", "hanging", "sluggish"])
    let macy = !wset.isDisjoint(with: ["mac", "macbook", "laptop", "computer", "pc", "system"])
    if (mem || cpu) && (appish || most) && wset.isDisjoint(with: ["remember", "forget", "clear", "reset", "delete"]) {
        return .topApps(cpu && !mem ? "cpu" : (mem && !cpu ? "memory" : "both"))
    }
    if slow && macy { return .topApps("both") }
    if appish && most && w.count <= 8 && !wset.isDisjoint(with: ["which", "what"]) { return .topApps("both") }
    return nil
}

func topAppsReport(_ kind: String) -> String {
    let out = runTool("/bin/ps", ["-A", "-c", "-o", "pcpu=", "-o", "rss=", "-o", "comm="])
    var cpu: [String: Double] = [:]
    var mem: [String: Double] = [:]
    for line in out.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let c = Double(parts[0]), let r = Double(parts[1]) else { continue }
        var name = String(parts[2]).trimmingCharacters(in: .whitespaces)
        if let h = name.range(of: " Helper") { name = String(name[..<h.lowerBound]) }
        if name == "kernel_task" || name == "ps" || name.isEmpty { continue }
        cpu[name, default: 0] += c
        mem[name, default: 0] += r / 1024.0       // megabytes
    }
    if mem.isEmpty { return "Sorry, I could not read the running apps." }
    func memText(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f gigabytes", mb / 1024) : "\(Int(mb)) megabytes"
    }
    func join(_ items: [String]) -> String { items.joined(separator: " and ") }
    var sentences: [String] = []
    let topMem = mem.sorted { $0.value > $1.value }.prefix(3).map { $0 }
    let topCpu = cpu.sorted { $0.value > $1.value }.prefix(3).map { $0 }
    if kind != "cpu", let first = topMem.first {
        var s = "\(first.key) is using the most memory, about \(memText(first.value))."
        if topMem.count > 1 {
            s += " Next are " + join(topMem.dropFirst().map { "\($0.key) with \(memText($0.value))" }) + "."
        }
        sentences.append(s)
    }
    if kind != "memory", let first = topCpu.first {
        var s = "\(first.key) is using the most processor power, about \(Int(first.value.rounded())) percent."
        if topCpu.count > 1 {
            s += " Next are " + join(topCpu.dropFirst().map { "\($0.key) with \(Int($0.value.rounded())) percent" }) + "."
        }
        sentences.append(s)
    }
    let tipName = (kind == "cpu" ? topCpu.first?.key : topMem.first?.key) ?? ""
    if !tipName.isEmpty, findRunningApp(tipName) != nil {
        sentences.append("Say close \(tipName) if you want to free it up.")
    }
    return sentences.joined(separator: " ")
}

func currentSpeechRate() -> Float {
    let v = UserDefaults.standard.float(forKey: "broRate")
    return v == 0 ? speechRate : v
}

let helpText = "I can open and close apps and websites, play music, set timers, alarms and reminders, tell the weather, news and time, change volume and brightness, take notes, keep a shopping list, do sums and conversions, write messages, summarize pages, and answer questions. Say text bar to type to me."

// More commands (v41). Called first from parseExtras.
func parseMore(_ text: String, _ w: [String]) -> VoiceCommand? {
    let wset = Set(w)
    let joined = w.joined(separator: " ")

    // keyboard backlight (v44)
    if let kb = parseKeyboardLight(text, w) { return kb }

    // which app uses the most memory / processor, why is the Mac slow (v46)
    if let top = parseTopApps(w) { return top }

    // help
    let helpPhrases: Set<String> = ["help", "what can you do", "what can you do for me", "show help", "list your commands",
                                    "what are your commands", "what do you do", "bro help"]
    if helpPhrases.contains(joined) { return .say(helpText) }

    // keyboard actions: "new tab", "scroll down", "paste", "next desktop"
    if w.count <= 6 {
        let fillers: Set<String> = ["bro", "please", "the", "a", "this", "that", "it", "my", "now", "here", "can", "you", "could", "just"]
        let core = w.filter { !fillers.contains($0) }.joined(separator: " ")
        if let script = keyActions[core] { return .keys(script) }
    }

    // spelling
    if let i = w.firstIndex(where: { $0 == "spell" || $0 == "spelling" }), w.count <= 8,
       !wset.contains("clipboard"), !wset.contains("check") {
        let skip: Set<String> = ["the", "word", "of", "for", "a", "how", "do", "you", "is", "to", "me", "bro", "please"]
        let after = Array(w[(i + 1)...]).filter { !skip.contains($0) }
        if let word = after.last {
            let letters = word.filter { $0.isASCII && $0.isLetter }
            if letters.count >= 2 {
                let spelled = letters.uppercased().map { String($0) }.joined(separator: ", ")
                return .say("\(letters) is spelled: \(spelled).")
            }
        }
    }

    // splitting a bill
    if w.contains("split") && w.count <= 10 {
        let nums = numbersIn(text)
        if nums.count >= 2 && nums[1] >= 1 {
            return .say("Each person pays \(formatShort(nums[0] / nums[1])).")
        }
    }

    // pomodoro (with a cancel word it stops the timers instead)
    if (wset.contains("pomodoro") || joined.contains("focus timer")) && w.count <= 5 {
        let cancelWords: Set<String> = ["cancel", "cancelled", "canceled", "stop", "stopped", "end", "delete", "remove", "clear", "off", "quit"]
        if !wset.isDisjoint(with: cancelWords) { return .cancelAlerts("timer") }
        return .pomodoro
    }

    // plain weather questions: "is it raining outside", "do I need an umbrella", "will it be hot today"
    let weatherHints: Set<String> = ["rain", "raining", "rainy", "umbrella", "sunny", "cloudy", "humid", "windy", "snowing",
                                     "storm", "hot", "cold", "foggy", "warm"]
    let notWeather: Set<String> = ["water", "food", "coffee", "tea", "drink", "milk", "soup", "shower", "pizza", "tap", "song", "music"]
    let whenWords: Set<String> = ["outside", "today", "tonight", "now", "tomorrow", "there"]
    if w.count <= 9 && !wset.isDisjoint(with: weatherHints) && wset.isDisjoint(with: notWeather)
        && (!wset.isDisjoint(with: whenWords) || wset.contains("umbrella")) {
        return .weather(nil)
    }

    // speaking speed
    if w.count <= 6 {
        let slow = wset.contains("slower") || wset.contains("slowly") || joined == "slow down"
        let fast = wset.contains("faster") || wset.contains("quicker")
        let about = !wset.isDisjoint(with: ["talk", "speak", "voice", "speech", "speed", "words", "speaking", "talking"])
        if (slow || fast) && (about || joined == "slow down") { return .speechRate(slow ? -1 : 1) }
        if (joined.contains("normal speed") || joined.contains("normal voice") || joined.contains("reset speed")
            || joined.contains("default speed")) { return .speechRate(0) }
    }

    // Mac facts
    if joined.contains("ip address") || joined == "my ip" || joined == "what is my ip" { return .sysInfo("ip") }
    if joined.contains("uptime") || (joined.contains("how long") && (wset.contains("on") || wset.contains("running")) && wset.contains("mac")) {
        return .sysInfo("uptime")
    }
    if w.count <= 7 && (wset.contains("memory") || wset.contains("ram"))
        && wset.isDisjoint(with: ["remember", "clear", "forget", "reset", "delete", "your"]) { return .sysInfo("memory") }

    // trash
    if joined.contains("empty") && wset.contains("trash") && w.count <= 5 { return .emptyTrash }
    if (joined == "open trash" || joined == "open the trash" || joined == "show trash") {
        return .openFolder(NSHomeDirectory() + "/.Trash")
    }
    return nil
}

func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

@discardableResult
func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
    var err: NSDictionary?
    let script = NSAppleScript(source: source)
    let result = script?.executeAndReturnError(&err)
    if let e = err {
        print("BRO: AppleScript problem: \(e)")
        return nil
    }
    return result
}

func asEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func currentVolume() -> Int {
    let r = runAppleScript("output volume of (get volume settings)")
    return Int(r?.int32Value ?? 50)
}

func setVolume(_ v: Int) {
    runAppleScript("set volume output volume \(max(0, min(100, v)))")
}

func ensureAccessibility() -> Bool {
    if AXIsProcessTrusted() { return true }
    // No system pop-up here (asking for it from inside BRO crashed the app); open the Accessibility page instead
    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(u)
    }
    return false
}

// Presses a media key: 16 play/pause, 17 next, 18 previous (works with Spotify, Music, YouTube in a browser).
func pressMediaKey(_ key: Int) {
    func post(_ down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
        let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        ev?.cgEvent?.post(tap: .cghidEventTap)
    }
    post(true)
    post(false)
}

// Types text into whichever app is in front.
func typeString(_ s: String) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let units = Array(s.utf16)
    var i = 0
    while i < units.count {
        let chunk = Array(units[i..<min(i + 16, units.count)])
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        i += 16
        usleep(8000)
    }
}

// MARK: - News and dictionary (need internet)

final class RSSTitles: NSObject, XMLParserDelegate {
    var titles: [String] = []
    var inItem = false
    var inTitle = false
    var current = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" { inItem = true }
        if inItem && elementName == "title" {
            inTitle = true
            current = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { current += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inTitle { current += String(data: CDATABlock, encoding: .utf8) ?? "" }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title" && inTitle {
            inTitle = false
            titles.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if elementName == "item" { inItem = false }
    }
}

func cleanHeadline(_ s: String) -> String {
    if let r = s.range(of: " - ", options: .backwards) { return String(s[..<r.lowerBound]) }
    return s
}

// Opens a link in a small Brave window with no tabs or address bar, so it looks like an app.
func openInBraveAppWindow(_ url: URL) -> Bool {
    let path = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["--app=" + url.absoluteString, "--autoplay-policy=no-user-gesture-required"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); return true } catch { return false }
}

// Finds the first video for a YouTube search, so a song can start playing by itself.
func findFirstVideoID(_ query: String) async -> String? {
    let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    guard let url = URL(string: "https://www.youtube.com/results?search_query=\(q)&sp=EgIQAQ%253D%253D") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                 forHTTPHeaderField: "User-Agent")
    req.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let ns = html as NSString
        for pattern in ["\"videoRenderer\":\\{\"videoId\":\"([A-Za-z0-9_-]{11})\"", "\"videoId\":\"([A-Za-z0-9_-]{11})\""] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    } catch {
        return nil
    }
}

// v47: looks at the first YouTube results and picks the most song-like one (not a cover, remix, live or reaction video).
func regexFirst(_ text: String, _ pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
    return ns.substring(with: m.range(at: 1))
}

func findBestVideoID(_ query: String, song: Bool) async -> String? {
    if !song { return await findFirstVideoID(query) }
    let lowerQ = query.lowercased()
    var search = query
    if !["audio", "video", "lyrics", "lyrical", "official"].contains(where: { lowerQ.contains($0) }) { search += " official audio" }
    let enc = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
    guard let url = URL(string: "https://www.youtube.com/results?search_query=\(enc)&sp=EgIQAQ%253D%253D") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                 forHTTPHeaderField: "User-Agent")
    req.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let html = String(data: data, encoding: .utf8) else { return await findFirstVideoID(query) }
    let parts = html.components(separatedBy: "\"videoRenderer\":{\"videoId\":\"")
    let qWords = commandWords(query).filter { !["play", "song", "songs", "music", "the", "please", "bro"].contains($0) }
    let bad = ["cover", "remix", "live", "reaction", "karaoke", "slowed", "reverb", "8d", "nightcore", "mashup", "instrumental",
               "tutorial", "lesson", "status", "shorts", "jukebox", "full album", "compilation", "ringtone", "dj", "trailer"]
    var best: (id: String, score: Double, title: String)? = nil
    for (i, full) in parts.dropFirst().prefix(8).enumerated() {
        let chunk = String(full.prefix(6000))
        guard chunk.count > 11 else { continue }
        let id = String(chunk.prefix(11))
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { continue }
        let title = (regexFirst(chunk, "\"title\":\\{\"runs\":\\[\\{\"text\":\"((?:[^\"\\\\]|\\\\.)*)\"") ?? "").lowercased()
        let titleWords = Set(commandWords(title))
        let squashed = normScalars(title)
        var score = -0.3 * Double(i)
        for w in qWords where squashed.contains(w) { score += 2 }
        for b in bad where !lowerQ.contains(b) {
            let hit = b.contains(" ") ? title.contains(b) : titleWords.contains(b)
            if hit { score -= 3 }
        }
        if let len = regexFirst(chunk, "\"lengthText\":\\{[\\s\\S]*?\"simpleText\":\"([0-9:]+)\"") {
            let nums = len.split(separator: ":").compactMap { Int($0) }
            var secs = 0
            for n in nums { secs = secs * 60 + n }
            if secs >= 90 && secs <= 420 { score += 2 } else if secs > 600 || secs < 60 { score -= 3 }
        }
        if titleWords.contains("official") { score += 1 }
        if titleWords.contains("audio") { score += 0.5 }
        if best == nil || score > best!.score { best = (id, score, title) }
    }
    if let b = best {
        print("BRO: song pick '\(b.title)' (score \(b.score))")
        return b.id
    }
    return await findFirstVideoID(query)
}

func fetchHeadlines(topic: String?) async -> String {
    var urlString = "https://news.google.com/rss?hl=en-IN&gl=IN&ceid=IN:en"
    if let t = topic, !t.isEmpty {
        let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
        urlString = "https://news.google.com/rss/search?q=\(q)&hl=en-IN&gl=IN&ceid=IN:en"
    }
    guard let url = URL(string: urlString) else { return "I could not open the news." }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    do {
        let (data, _) = try await URLSession.shared.data(for: req)
        let parser = XMLParser(data: data)
        let rss = RSSTitles()
        parser.delegate = rss
        parser.parse()
        let items = rss.titles.prefix(3).map { cleanHeadline($0) }
        if items.isEmpty { return "I could not find any news." }
        return "Here are the top headlines. " + items.joined(separator: ". ") + "."
    } catch {
        return "I could not get the news. Please check your internet connection."
    }
}

func fetchDefinition(_ word: String) async -> String {
    let q = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
    guard let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(q)") else {
        return "I could not look that up."
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 404 { return "I could not find the word \(word)." }
        if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let meanings = arr.first?["meanings"] as? [[String: Any]],
           let m = meanings.first,
           let defs = m["definitions"] as? [[String: Any]],
           let d = defs.first?["definition"] as? String {
            let part = (m["partOfSpeech"] as? String) ?? ""
            return part.isEmpty ? "\(word): \(d)" : "\(word), \(part): \(d)"
        }
        return "I could not find the word \(word)."
    } catch {
        return "I could not look that up. Please check your internet connection."
    }
}

// Timers, alarms and reminders that BRO keeps (they survive restarts).
struct BroAlert: Codable {
    var id: String
    var kind: String      // "timer", "alarm" or "reminder"
    var fire: Date
    var message: String
    var repeatRule: String? = nil     // nil, "daily" or "weekly"
}


// Plays the songs from this Mac inside BRO itself, so BRO can pause, skip and stop them.
final class LocalPlayer: NSObject, AVAudioPlayerDelegate {
    var onStopped: (() -> Void)?
    private var player: AVAudioPlayer?
    private var queue: [URL] = []
    private var index = 0

    var isActive: Bool { player != nil }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var level: Float = 1.0          // 1.0 normal; lower while the talk key is held (v48)
    func setLevel(_ v: Float) { level = v; player?.volume = v }

    func play(queue newQueue: [URL]) {
        guard !newQueue.isEmpty else { return }
        queue = newQueue
        index = 0
        startCurrent()
    }

    private func startCurrent() {
        guard queue.indices.contains(index) else { stop(); return }
        do {
            let p = try AVAudioPlayer(contentsOf: queue[index])
            p.delegate = self
            p.volume = level
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            print("BRO: could not play \(queue[index].lastPathComponent): \(error.localizedDescription)")
            index += 1
            if queue.indices.contains(index) { startCurrent() } else { stop() }
        }
    }

    func pause() { player?.pause() }
    func resume() { player?.play() }

    func next() {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        startCurrent()
    }

    func previous() {
        guard !queue.isEmpty else { return }
        index = (index - 1 + queue.count) % queue.count
        startCurrent()
    }

    func stop() {
        let wasActive = player != nil
        player?.stop()
        player = nil
        queue = []
        index = 0
        if wasActive { onStopped?() }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        index += 1
        if queue.indices.contains(index) { startCurrent() } else { stop() }
    }
}

// All song files in the Music/songs folder, in alphabetical order.
func allLocalSongs() -> [URL] {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: URL(fileURLWithPath: localMusicFolder), includingPropertiesForKeys: nil,
                                options: [.skipsHiddenFiles]) else { return [] }
    let kinds: Set<String> = ["mp3", "m4a", "wav", "aac", "flac"]
    var out: [URL] = []
    for case let url as URL in e {
        if e.level > 2 { e.skipDescendants(); continue }
        if kinds.contains(url.pathExtension.lowercased()) { out.append(url) }
    }
    return out.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
}

// Folder with the songs saved on this Mac
let localMusicFolder = NSHomeDirectory() + "/Music/songs"

// Finds the best matching song file for what was said. File names are messy ("1 Song_(Official Video).mp3"),
// so every spoken word is looked for inside the file name with all spaces and symbols removed.
func findLocalSong(_ query: String) -> URL? {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: localMusicFolder)
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
    let skip: Set<String> = ["the", "a", "an", "song", "songs", "music", "by", "of", "please", "bro"]
    let words = commandWords(query).filter { !skip.contains($0) }
    guard !words.isEmpty else { return nil }
    let need = max(1, (words.count * 2 + 2) / 3)          // at least two thirds of the spoken words must match
    let kinds: Set<String> = ["mp3", "m4a", "wav", "aac", "flac"]
    var best: (url: URL, score: Int, len: Int)? = nil
    for case let url as URL in e {
        if e.level > 2 { e.skipDescendants(); continue }
        guard kinds.contains(url.pathExtension.lowercased()) else { continue }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let squashed = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) })
        var score = 0
        for w in words {
            // a long word may be heard a little wrong at the end, so its last two letters are allowed to differ
            if squashed.contains(w) || (w.count >= 6 && squashed.contains(String(w.dropLast(2)))) { score += 1 }
        }
        guard score >= need else { continue }
        // best score wins; on a tie the shorter name wins (this skips duplicates like "1 Song.mp3")
        if best == nil || score > best!.score || (score == best!.score && squashed.count < best!.len) {
            best = (url, score, squashed.count)
        }
    }
    return best?.url
}

// Smart commands: only short sentences with one of these words are shown to the brain (so normal chat is not slowed down).
func smartPrefilter(_ text: String) -> Bool {
    let w = commandWords(text)
    guard w.count >= 2, w.count <= 9 else { return false }
    let hints: Set<String> = ["dark", "darker", "dim", "dimmer", "bright", "brighter", "light", "lighter", "loud", "louder",
                              "quiet", "quieter", "silent", "softer", "sound", "volume", "noise", "screen", "mute", "unmute",
                              "skip", "next", "previous", "pause", "resume", "music", "song", "night",
                              "weather", "raining", "rain", "umbrella", "hot", "cold", "battery", "charging", "news", "headlines", "screenshot",
                              "keyboard", "backlit", "backlight", "lock", "slow", "laggy", "lagging", "sluggish", "hanging", "freezing",
                              "tab", "scroll", "refresh", "reload", "calendar", "schedule", "meetings", "agenda", "disk", "storage",
                              "wifi", "internet", "shopping", "reminders", "timer", "briefing", "shuffle", "slower", "faster", "memory",
                              "hear", "hearing", "noisy", "charged", "charge", "world", "new", "happening", "hang", "hangs",
                              "hung", "secure", "protect", "laptop", "repeat", "random", "stop"]
    return !Set(w).isDisjoint(with: hints)
}

// True when the sentence is an order to do something on the Mac ("close the window", "turn on bluetooth").
// If BRO has no real command for it, the AI must not be asked: it would only pretend to have done it.
func looksLikeAction(_ text: String) -> Bool {
    var w = commandWords(text)
    let lead: Set<String> = ["bro", "please", "can", "could", "would", "will", "you", "hey", "just", "now", "kindly", "ok", "okay"]
    while let f = w.first, lead.contains(f) { w.removeFirst() }
    guard let first = w.first, w.count >= 2 else { return false }
    let verbs: Set<String> = ["open", "close", "play", "pause", "resume", "stop", "launch", "quit", "exit", "turn", "switch",
                              "send", "delete", "lock", "mute", "unmute", "increase", "decrease", "raise", "lower",
                              "enable", "disable", "toggle", "download", "install", "uninstall", "restart", "reboot",
                              "click", "press", "minimize", "maximize", "hide", "skip"]
    return verbs.contains(first)
}

func parseCommand(_ text: String) -> VoiceCommand? {
    let w = commandWords(text)
    if w.isEmpty { return nil }
    let joined = w.joined(separator: " ")
    let hasBro = w.contains("bro") || w.contains("ब्रो")
    let wset = Set(w)

    // ---- more Mac commands ----
    let firstWord = w.first ?? ""
    let notACommand: Set<String> = ["search", "type", "define", "meaning", "note", "remind", "what", "whats", "who", "why", "how", "tell"]

    // "stop music", "stop the song"
    if wset.contains("stop") && !wset.isDisjoint(with: ["music", "song", "songs", "track", "playing", "playback"]) && w.count <= 5 {
        return .stopMusic
    }
    // "close the song", "close this song", "turn off the music", "kill the song": ends the song for good
    let endWords: Set<String> = ["close", "quit", "exit", "kill", "end", "finish", "remove", "cancel"]
    if w.count <= 6 && !wset.contains("youtube") && !wset.contains("app") && !wset.contains("application")
        && (!wset.isDisjoint(with: endWords) || joined.contains("turn off") || joined.contains("switch off"))
        && !wset.isDisjoint(with: ["music", "song", "songs", "track", "playing"]) {
        return .closeSong
    }
    // "play a random song", "shuffle my songs", "play all songs"
    let songNouns: Set<String> = ["song", "songs", "music", "track", "tracks"]
    if w.count <= 7 && !wset.isDisjoint(with: songNouns) && !wset.contains("youtube") {
        if wset.contains("random") || wset.contains("shuffle") { return .playRandomSong }
        if firstWord == "play" && wset.contains("all") { return .playAllSongs }
    }
    // "open downloads", "open the desktop folder", "open my songs folder"
    if firstWord == "open" {
        let folders: [String: String] = ["downloads": "Downloads", "desktop": "Desktop", "documents": "Documents",
                                         "pictures": "Pictures", "movies": "Movies"]
        if wset.contains("songs") && wset.contains("folder") { return .openFolder(localMusicFolder) }
        if wset.contains("home") && wset.contains("folder") { return .openFolder(NSHomeDirectory()) }
        if wset.contains("music") && wset.contains("folder") { return .openFolder(NSHomeDirectory() + "/Music") }
        if let key = w.first(where: { folders[$0] != nil }), wset.contains("folder") || w.count <= 2 {
            return .openFolder(NSHomeDirectory() + "/" + (folders[key] ?? ""))
        }
    }
    // v50: "it is too dark to type", "I cannot see the screen" -> brighter; "too bright", "hurts my eyes" -> dimmer
    if w.count <= 9 && !notACommand.contains(firstWord) && !mentionsKeyboardLight(w) {
        let j = w.joined(separator: " ")
        let wantsBrighter = ["too dark", "so dark", "very dark", "cant see", "can't see", "cannot see", "can not see", "hard to see", "difficult to see", "screen is dark", "screen dark"]
        let wantsDimmer = ["too bright", "so bright", "very bright", "hurts my eyes", "hurting my eyes", "eyes hurt", "eyes are hurting"]
        if wantsBrighter.contains(where: { j.contains($0) }) { return .brightnessChange(3) }
        if wantsDimmer.contains(where: { j.contains($0) }) { return .brightnessChange(-3) }
    }
    // "brightness up", "set brightness to 50", "make it dimmer"
    if !wset.isDisjoint(with: ["brightness", "brighter", "dimmer", "darker"]) && w.count <= 7 && !notACommand.contains(firstWord)
        && !mentionsKeyboardLight(w) {
        let upW: Set<String> = ["up", "increase", "raise", "higher", "more", "brighter"]
        let downW: Set<String> = ["down", "decrease", "lower", "less", "reduce", "dimmer", "darker", "dim"]
        if let n = w.compactMap({ Int($0) }).first { return .brightnessSet(min(100, max(0, n))) }
        if wset.isDisjoint(with: upW) && wset.isDisjoint(with: downW), let n = spokenNumber(w) {
            return .brightnessSet(min(100, max(0, n)))
        }
        if !wset.isDisjoint(with: ["max", "maximum", "full"]) { return .brightnessSet(100) }
        if !wset.isDisjoint(with: ["min", "minimum"]) { return .brightnessSet(0) }
        if !wset.isDisjoint(with: upW) { return .brightnessChange(3) }
        if !wset.isDisjoint(with: downW) { return .brightnessChange(-3) }
    }
    // "what is on my calendar today", "my schedule", "any meetings today"
    if !wset.isDisjoint(with: ["calendar", "schedule", "meetings", "events", "agenda"])
        && !wset.isDisjoint(with: ["today", "my", "on"]) && w.count <= 8
        && !["search", "type", "define", "meaning", "note", "remind"].contains(firstWord)
        && wset.isDisjoint(with: ["add", "create", "open", "close", "delete"]) {
        return .calendarToday
    }
    // "run shortcut focus on", "shortcut focus on", "run focus on shortcut"
    if wset.contains("shortcut") && !wset.contains("change") && !wset.contains("keyboard") {
        let skipWords: Set<String> = ["run", "start", "the", "my", "bro", "please", "execute", "activate", "launch", "open"]
        if let i = w.firstIndex(of: "shortcut") {
            let after = Array(w[(i + 1)...]).filter { !skipWords.contains($0) }
            let before = Array(w[..<i]).filter { !skipWords.contains($0) }
            let q = (after.isEmpty ? before : after).joined(separator: " ")
            if !q.isEmpty { return .runShortcut(q) }
        }
    }
    // "turn wifi off", "wifi on"
    if (wset.contains("wifi") || joined.contains("wi fi"))
        && ["turn", "switch", "enable", "disable", "wifi", "bro", "please", "connect", "disconnect"].contains(firstWord) {
        if !wset.isDisjoint(with: ["off", "disable", "disconnect"]) { return .wifiPower(false) }
        if !wset.isDisjoint(with: ["on", "enable", "connect"]) { return .wifiPower(true) }
    }
    let t = timeTokens(w)
    let stopWords: Set<String> = ["cancel", "cancelled", "canceled", "cancelling", "canceling", "stop", "stopped", "delete", "remove", "clear", "off"]
    if let extra = parseExtras(text, w) { return extra }

    // "type hello world" types it into the app in front
    if w.first == "type" && w.count >= 2 {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sp = raw.firstIndex(of: " ") {
            let body = String(raw[raw.index(after: sp)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return .typeText(body) }
        }
    }

    // "take a note buy milk", "note down call the bank"
    if let ni = w.firstIndex(where: { $0 == "note" || $0 == "notes" }) {
        let noteVerbs: Set<String> = ["take", "make", "write", "add", "create", "save", "jot", "new"]
        let before = Set(w[..<ni])
        let isNote = !before.isDisjoint(with: noteVerbs) || (ni + 1 < w.count && w[ni + 1] == "down")
        if isNote {
            var rest = Array(w[(ni + 1)...])
            let skip: Set<String> = ["down", "that", "saying", "to", "of", "about", "which", "says"]
            while let f = rest.first, skip.contains(f) { rest.removeFirst() }
            return .note(rest.joined(separator: " "))
        }
    }

    // "remind me to call mom at 5 pm", "remind me in 10 minutes to check the oven"
    if w.contains("remind") { return parseReminder(t) }

    // Timers and alarms
    if w.contains("timer") || w.contains("timers") {
        if !wset.isDisjoint(with: stopWords) { return .cancelAlerts("timer") }
        if joined.contains("left") || joined.contains("remaining") || joined.contains("how long") || joined.contains("how much") {
            return .timeLeft
        }
        if let d = parseDuration(t) { return .timer(d.seconds) }
        return .say("For how long? Say for example: set a timer for 10 minutes.")
    }
    if w.contains("alarm") || w.contains("alarms") || joined.contains("wake me") {
        if !wset.isDisjoint(with: stopWords) { return .cancelAlerts("alarm") }
        if let d = parseDuration(t) { return .alarm(Date().addingTimeInterval(Double(d.seconds))) }
        if let c = parseClock(t),
           let date = nextTime(hour: c.hour, minute: c.minute, explicit: c.explicit, tomorrow: t.contains("tomorrow")) {
            return .alarm(date)
        }
        return .say("What time? Say for example: set an alarm for 7 AM.")
    }

    // Weather: "what's the weather", "weather in Delhi"
    if w.count <= 10 && (w.contains("weather") || w.contains("temperature") || w.contains("forecast")) {
        var city: String? = nil
        if let i = w.lastIndex(of: "in"), i + 1 < w.count {
            let skip: Set<String> = ["today", "now", "tomorrow", "like", "right", "outside", "currently", "tonight", "the"]
            let c = w[(i + 1)...].filter { !skip.contains($0) }.prefix(3)
            if !c.isEmpty { city = c.joined(separator: " ") }
        }
        return .weather(city)
    }

    // News and cricket
    if w.contains("news") || w.contains("headlines") {
        var topic: String? = nil
        if let i = w.firstIndex(where: { $0 == "about" || $0 == "on" }), i + 1 < w.count {
            topic = w[(i + 1)...].joined(separator: " ")
        }
        return .news(topic)
    }
    if joined.contains("cricket") && (joined.contains("score") || joined.contains("match")) {
        return .news("cricket live score")
    }

    // Word meanings
    if w.first == "define" && w.count >= 2 { return .define(w[1]) }
    if let i = w.firstIndex(of: "meaning"), i + 2 < w.count, w[i + 1] == "of" { return .define(w[i + 2]) }
    if w.count >= 4 && w[0] == "what" && w[1] == "does" && w.last == "mean" { return .define(w[w.count - 2]) }

    // Sums: "what is 245 times 18"
    if w.count <= 16, let ans = calcAnswer(text) { return .say(ans) }

    // Searching: "search for best phones", "play lofi on youtube"
    // Playing a song: "play kesariya on youtube music", "play lofi on youtube", "play believer"
    var pw = w
    if pw.first == "bro" { pw.removeFirst() }
    if pw.first == "play" && pw.count >= 2 && !wset.contains("spotify") {
        let rest = Array(pw.dropFirst())
        let mentionsYouTube = rest.contains(where: { ["youtube", "yt", "ytmusic", "youtubemusic"].contains($0) })
        let mentionsMusic = rest.contains("music") || rest.contains("ytmusic") || rest.contains("youtubemusic")
        let onlyMediaWords = Set(rest).isSubset(of: ["music", "song", "track", "the", "please", "a", "this", "playing", "bro"])
        // "play local kesariya", "play kesariya from my mac": only look on this Mac
        let localWords: Set<String> = ["local", "locally", "offline", "downloaded"]
        let wantsLocal = rest.contains(where: { localWords.contains($0) })
            || (rest.contains("my") && (rest.contains("mac") || rest.contains("macbook") || rest.contains("laptop") || rest.contains("computer")))
        if wantsLocal && !mentionsYouTube {
            let dropLocal: Set<String> = ["local", "locally", "offline", "downloaded", "my", "mac", "macbook", "laptop", "computer",
                                          "from", "on", "in", "the", "please", "bro", "song", "songs", "music", "files", "file", "folder"]
            return .playLocalSong(rest.filter { !dropLocal.contains($0) }.joined(separator: " "))
        }
        if mentionsYouTube || !onlyMediaWords {
            let drop: Set<String> = ["on", "in", "from", "using", "with", "youtube", "yt", "ytmusic", "youtubemusic",
                                     "bro", "please", "the", "app"]
            var song = rest.filter { !drop.contains($0) }
            if mentionsYouTube && mentionsMusic { song.removeAll { $0 == "music" } }
            // YouTube Music is the default; only "on youtube" (without "music") uses normal YouTube
            let useMusic = mentionsYouTube ? mentionsMusic : true
            let q = song.joined(separator: " ")
            if q.isEmpty { return useMusic ? .openApp("youtube music") : .search("", true) }
            // no platform named: songs on this Mac come first, YouTube Music is the fallback
            if !mentionsYouTube { return .playAnySong(q) }
            return .playSong(q, useMusic)
        }
    }
    var searchWords: [String]? = nil
    if let f = w.first, (f == "search" || f == "lookup"), w.count >= 2 {
        searchWords = Array(w.dropFirst())
    } else if w.count >= 3 && w[0] == "look" && w[1] == "up" {
        searchWords = Array(w.dropFirst(2))
    }
    if var q = searchWords {
        let filler: Set<String> = ["for", "on", "the", "web", "google", "about", "up", "in", "bro"]
        while let f = q.first, filler.contains(f) { q.removeFirst() }
        var yt = false
        if q.first == "youtube" {
            yt = true
            q.removeFirst()
            while let f = q.first, filler.contains(f) { q.removeFirst() }
        }
        if !q.isEmpty { return .search(q.joined(separator: " "), yt) }
    }

    if w.contains("forget") && w.count <= 6 { return .forget }

    if w.count > 8 { return nil }

    // Volume
    if wset.contains("unmute") { return .volumeMute(false) }
    if wset.contains("mute") { return .volumeMute(true) }
    if wset.contains("volume") || wset.contains("louder") || wset.contains("quieter") {
        let upWords: Set<String> = ["up", "increase", "raise", "higher", "louder"]
        let downWords: Set<String> = ["down", "decrease", "lower", "quieter", "softer", "reduce"]
        if let n = w.compactMap({ Int($0) }).first(where: { $0 >= 0 && $0 <= 100 }) { return .volumeSet(n) }
        if wset.contains("max") || wset.contains("full") || wset.contains("maximum") { return .volumeSet(100) }
        if !wset.isDisjoint(with: upWords) { return .volumeChange(12) }
        if !wset.isDisjoint(with: downWords) { return .volumeChange(-12) }
        if joined.contains("what") || joined.contains("how") { return .volumeAsk }
    }

    // Music keys: "pause", "next song", "play music"
    let mediaWords: Set<String> = ["play", "pause", "resume", "next", "skip", "previous", "last", "back", "song",
                                   "music", "track", "the", "please", "bro", "stop", "this", "a", "playing"]
    if w.count <= 4 && wset.isSubset(of: mediaWords) {
        if wset.contains("next") || wset.contains("skip") { return .media(17) }
        if wset.contains("previous")
            || (!wset.isDisjoint(with: ["back", "last"]) && !wset.isDisjoint(with: ["song", "track", "music"])) {
            return .media(18)
        }
        if wset.contains("play") || wset.contains("pause") || wset.contains("resume") || wset.contains("stop") {
            return .media(16)
        }
    }

    // Mac information and control
    // v52: "how charged is my laptop", "how much charge is left"
    if w.count <= 8 && (wset.contains("charged") || wset.contains("charge")) && wset.contains("how")
        && wset.isDisjoint(with: ["phone", "iphone", "airpods", "watch", "ipad"]) { return .battery }
    // v52: "anything new in the world", "what is happening today"
    if w.count <= 8 && ["anything new", "whats new", "what is new", "what is happening", "whats happening", "what is going on in the world"].contains(where: { joined.contains($0) })
        && !wset.isDisjoint(with: ["world", "today", "news", "around", "india"]) { return .news(nil) }
    if wset.contains("battery") { return .battery }
    if wset.contains("wifi") || joined.contains("wi fi") || wset.contains("internet") { return .wifi }
    if joined.contains("disk space") || joined.contains("storage") || joined.contains("space left") || joined.contains("free space") {
        return .disk
    }
    if wset.contains("clipboard") { return .clipboard }
    if (wset.contains("dark") || wset.contains("light")) && wset.contains("mode") {
        if wset.contains("toggle") { return .darkMode(-1) }
        return .darkMode((wset.contains("light") || wset.contains("off")) ? 0 : 1)
    }
    if wset.contains("lock") && (!wset.isDisjoint(with: ["screen", "mac", "computer", "laptop", "macbook"]) || w.count <= 2) {
        return .lockScreen
    }
    if joined.contains("go to sleep") || joined == "sleep now" || (wset.contains("sleep") && !wset.isDisjoint(with: macWords)) {
        return .sleepMac
    }
    if joined.contains("screenshot") || joined.contains("screen shot") || joined.contains("screen capture") {
        return .screenshot
    }

    // Time and date come straight from the Mac's clock
    if joined.contains("what time") || joined.contains("time is it") || joined.contains("current time")
        || joined.contains("the time") || joined == "time" {
        return .time
    }
    if joined.contains("the date") || joined.contains("todays date") || joined.contains("what day")
        || joined.contains("which day") {
        return .date
    }

    // "close youtube music", "close youtube music inside my brave browser"
    if w.contains(where: { closeVerbs.contains($0) }) && w.count <= 10
        && (joined.contains("youtube music") || wset.contains("ytmusic") || wset.contains("youtubemusic")) {
        return .closeYTMusic
    }

    // "close WhatsApp", "quit Safari", "WhatsApp band karo", "व्हाट्सऐप बंद करो"
    // (a close word plus an app name; with no app name it falls through to the shutdown rules below)
    if w.count <= 5 && w.contains(where: { closeVerbs.contains($0) }) {
        let nameWords = w.filter { !closeVerbs.contains($0) && !fillerWords.contains($0) && !closeFillers.contains($0) }
        if nameWords.count >= 1 && nameWords.count <= 3 && !nameWords.contains("shutdown") && !nameWords.contains("down") {
            return .closeApp(nameWords.joined(separator: " "))
        }
    }

    // "bro shutdown", "shut down", "quit", "exit" (only short sentences, and not about the Mac itself)
    if w.count <= 5 && Set(w).isDisjoint(with: macWords) {
        if w.contains("shutdown") || w.contains("quit") || w.contains("exit") || w.contains("poweroff")
            || joined.contains("shut down")
            || ((joined.contains("turn off") || joined.contains("power off")) && (hasBro || w.count <= 2)) {
            return .shutdown
        }
    }
    // Hindi / Hinglish: "band ho ja", "band karo", "बंद हो जाओ", "ब्रो बंद करो"
    let band = ["band ho", "band kar", "बंद हो", "बंद कर", "बन्द हो", "बन्द कर"]
    if band.contains(where: { joined.contains($0) }) {
        let first = w.first ?? ""
        if hasBro || first == "band" || first == "बंद" || first == "बन्द" { return .shutdown }
    }

    // "open YouTube in Brave", "open youtube music inside my brave browser"
    let browsers: [String: String] = ["brave": "Brave Browser", "chrome": "Google Chrome", "safari": "Safari",
                                      "firefox": "Firefox", "edge": "Microsoft Edge"]
    if w.contains(where: { openVerbs.contains($0) }),
       let bi = w.firstIndex(where: { browsers[$0] != nil }), bi >= 2 {
        let preps: Set<String> = ["in", "inside", "on", "using", "with"]
        if let pi = w[..<bi].lastIndex(where: { preps.contains($0) }) {
            let skip = openVerbs.union(fillerWords).union(["my", "browser", "tab", "new", "website", "site"])
            let nameWords = w[..<pi].filter { !skip.contains($0) }
            if !nameWords.isEmpty && nameWords.count <= 3 {
                return .openIn(nameWords.joined(separator: " "), browsers[w[bi]] ?? "")
            }
        }
    }

    // "open WhatsApp", "WhatsApp kholo", "व्हाट्सऐप खोलो"
    if w.contains(where: { openVerbs.contains($0) }) {
        let nameWords = w.filter { !openVerbs.contains($0) && !fillerWords.contains($0) }
        if nameWords.count >= 1 && nameWords.count <= 3 {
            return .openApp(nameWords.joined(separator: " "))
        }
    }
    return nil
}

// Spoken name (key without spaces) -> real app name. Includes common Whisper spellings and Hindi spellings.
let appAliases: [String: String] = [
    "whatsapp": "WhatsApp", "whatsup": "WhatsApp", "whatsap": "WhatsApp", "watsapp": "WhatsApp",
    "व्हाट्सएप": "WhatsApp", "व्हाट्सऐप": "WhatsApp", "वाट्सएप": "WhatsApp", "वाट्सऐप": "WhatsApp",
    "वॉट्सऐप": "WhatsApp", "वॉट्सएप": "WhatsApp", "व्हाट्सअप": "WhatsApp",
    "chrome": "Google Chrome", "googlechrome": "Google Chrome", "क्रोम": "Google Chrome", "गूगलक्रोम": "Google Chrome",
    "safari": "Safari", "सफारी": "Safari", "सफ़ारी": "Safari",
    "notes": "Notes", "note": "Notes", "नोट्स": "Notes",
    "spotify": "Spotify", "स्पॉटिफाई": "Spotify", "स्पोटिफाई": "Spotify",
    "mail": "Mail", "email": "Mail", "मेल": "Mail",
    "calendar": "Calendar", "कैलेंडर": "Calendar",
    "messages": "Messages", "message": "Messages", "मैसेज": "Messages", "मैसेजेस": "Messages",
    "music": "Music", "म्यूजिक": "Music", "म्यूज़िक": "Music",
    "settings": "System Settings", "systemsettings": "System Settings", "सेटिंग्स": "System Settings", "सेटिंग": "System Settings",
    "terminal": "Terminal", "टर्मिनल": "Terminal",
    "finder": "Finder", "फाइंडर": "Finder",
    "photos": "Photos", "फोटोज": "Photos", "फोटोस": "Photos", "फोटो": "Photos",
    "maps": "Maps", "मैप्स": "Maps",
    "facetime": "FaceTime", "फेसटाइम": "FaceTime",
    "calculator": "Calculator", "कैलकुलेटर": "Calculator",
    "appstore": "App Store", "ऐपस्टोर": "App Store",
    "reminders": "Reminders", "रिमाइंडर्स": "Reminders",
    "telegram": "Telegram", "टेलीग्राम": "Telegram",
    "vscode": "Visual Studio Code", "visualstudiocode": "Visual Studio Code",
    "jan": "Jan", "जन": "Jan"
]

func installedApps() -> [(name: String, url: URL)] {
    let fm = FileManager.default
    let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    var out: [(name: String, url: URL)] = []
    // Also looks one folder deeper, where Brave and Chrome keep "Install as app" web apps.
    func scan(_ d: String, depth: Int) {
        guard let items = try? fm.contentsOfDirectory(atPath: d) else { return }
        for it in items {
            let full = d + "/" + it
            if it.hasSuffix(".app") {
                out.append((name: String(it.dropLast(4)), url: URL(fileURLWithPath: full)))
            } else if depth > 0 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    scan(full, depth: depth - 1)
                }
            }
        }
    }
    for d in dirs { scan(d, depth: 1) }
    // Finder lives in a system folder that is not scanned, so it is added by hand
    out.append((name: "Finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")))
    return out
}

// Home city for "what's the weather" (change these three lines to move BRO's home)
let homeCity = "New Delhi"
let homeLat = 28.6139
let homeLon = 77.2090

func weatherWords(_ code: Int) -> String {
    switch code {
    case 0: return "clear"
    case 1: return "mostly clear"
    case 2: return "partly cloudy"
    case 3: return "overcast"
    case 45, 48: return "foggy"
    case 51, 53, 55, 56, 57: return "drizzling"
    case 61, 63, 65, 66, 67: return "raining"
    case 71, 73, 75, 77, 85, 86: return "snowing"
    case 80, 81, 82: return "showery"
    case 95, 96, 99: return "stormy with thunder"
    default: return "unsettled"
    }
}

// Uses the free Open-Meteo service (needs internet, no account or key).
func fetchWeather(city: String?) async -> String {
    var name = homeCity
    var lat = homeLat
    var lon = homeLon
    do {
        if let c = city {
            let q = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? c
            var greq = URLRequest(url: URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=en")!)
            greq.timeoutInterval = 15
            let (gd, _) = try await URLSession.shared.data(for: greq)
            guard let g = try JSONSerialization.jsonObject(with: gd) as? [String: Any],
                  let rs = g["results"] as? [[String: Any]], let r = rs.first,
                  let la = r["latitude"] as? Double, let lo = r["longitude"] as? Double else {
                return "I could not find a place called \(c)."
            }
            lat = la
            lon = lo
            name = (r["name"] as? String) ?? c
        }
        let u = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,weather_code&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto"
        var req = URLRequest(url: URL(string: u)!)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = obj["current"] as? [String: Any],
              let t = cur["temperature_2m"] as? Double,
              let code = cur["weather_code"] as? Int else {
            return "I could not read the weather report."
        }
        var text = "In \(name) it is \(Int(t.rounded())) degrees Celsius and \(weatherWords(code))."
        if let f = cur["apparent_temperature"] as? Double { text += " It feels like \(Int(f.rounded()))." }
        if let d = obj["daily"] as? [String: Any],
           let hi = (d["temperature_2m_max"] as? [Double])?.first,
           let lo = (d["temperature_2m_min"] as? [Double])?.first {
            text += " Today's high is \(Int(hi.rounded())) and the low is \(Int(lo.rounded()))."
        }
        return text
    } catch {
        return "I could not get the weather. Please check your internet connection."
    }
}

func canonicalAppName(_ spoken: String) -> String {
    let key = normScalars(spoken.replacingOccurrences(of: " ", with: ""))
    return appAliases[key] ?? spoken
}

// Finds an app that is open right now (never BRO itself or Finder).
func findRunningApp(_ spoken: String) -> NSRunningApplication? {
    let wanted = normScalars(canonicalAppName(spoken).replacingOccurrences(of: " ", with: ""))
    guard !wanted.isEmpty else { return nil }
    let me = Bundle.main.bundleIdentifier
    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.bundleIdentifier != me
            && $0.bundleIdentifier != "com.apple.finder" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
    let named = apps.map { (key: normScalars(($0.localizedName ?? "").replacingOccurrences(of: " ", with: "")), app: $0) }
    if let a = named.first(where: { $0.key == wanted }) { return a.app }
    if let a = named.first(where: { $0.key.hasPrefix(wanted) }) { return a.app }
    if wanted.count >= 4, let a = named.first(where: { $0.key.contains(wanted) }) { return a.app }
    return nil
}

func findApp(_ spoken: String) -> URL? {
    let key = normScalars(spoken.replacingOccurrences(of: " ", with: ""))
    let canonical = appAliases[key] ?? spoken
    let wanted = normScalars(canonical.replacingOccurrences(of: " ", with: ""))
    guard !wanted.isEmpty else { return nil }
    let apps = installedApps().map { (key: normScalars($0.name.replacingOccurrences(of: " ", with: "")), url: $0.url) }
    if let a = apps.first(where: { $0.key == wanted }) { return a.url }
    if let a = apps.first(where: { $0.key.hasPrefix(wanted) }) { return a.url }
    if wanted.count >= 4, let a = apps.first(where: { $0.key.contains(wanted) }) { return a.url }
    return nil
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVSpeechSynthesizerDelegate {
    let synth = AVSpeechSynthesizer()
    var history: [[String: String]] = []
    var pendingSpeech = 0
    let chat = ChatModel()
    var textPanel: TextPanel?
    var textKey: HotKey?
    var stopwatchStart: Date?
    var lastSpoken = ""
    var quietSpeech = false
    var chainNotes: [String] = []      // v54: what the earlier commands of a chain wanted to say
    var lastBrowser: String?
    var lastBrowserTime = Date.distantPast
    var batteryWarned: Set<Int> = []
    var batteryTimer: Timer?
    var pendingCommand: VoiceCommand? = nil   // a risky command that waits for "yes" or "no"
    var pendingSince = Date()
    var skipConfirm = false
    var waitingForBrain = false      // true while the brain is thinking, so the microphone stays closed
    let localPlayer = LocalPlayer()
    var holdKey: HoldKey?
    var pttHeld = false
    var pttBuffer: [Float] = []
    // Mix mode: BRO listens by itself, except while its own songs are playing. Then the talk key must be held.
    var holdToTalkNow: Bool { pushToTalk && localPlayer.isPlaying }
    var panel: OrbPanel!
    let model = OrbModel()
    let mic = MicMonitor()
    let endpointer = Endpointer()
    var stt: WhisperKit?
    var sttLoading = false
    var isShown = false
    var restOrigin: NSPoint?
    var hotKey: HotKey?
    var shortcutKey: UInt32 = UInt32(kVK_ANSI_B)
    var shortcutMods: UInt32 = UInt32(optionKey)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        history = (UserDefaults.standard.array(forKey: "broHistory") as? [[String: String]]) ?? []
        loadAlerts()
        loadOrbColor()
        chat.onSend = { [weak self] t in self?.submitTyped(t) }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.checkBattery() }
        textKey = HotKey(id: 3) { [weak self] in self?.toggleTextBar() }
        textKey?.register(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey))

        let size = NSSize(width: 320, height: 320)
        panel = OrbPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: OrbView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        model.onReplay = { [weak self] in
            self?.restOrigin = self?.panel.frame.origin
            self?.playActivation()
        }
        mic.onChunk = { [weak self] rms, samples in self?.handleChunk(rms: rms, samples: samples) }
        // v53: watchdog. If the orb says "listening" but the microphone sends nothing, restart it.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, self.isShown, self.model.state == .listening, !self.pttHeld else { return }
            if Date().timeIntervalSince(self.mic.lastChunk) > 3 {
                print("BRO: the microphone went silent, restarting it")
                self.mic.stop()
                self.startListening()
            }
        }
        synth.delegate = self
        // The built-in brain: the very first time only, download the model in the background (about 2 GB, internet needed once).
        Task {
            await Brain.shared.prepareIfNeeded(onDownloadStart: { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, self.isShown else { return }
                    self.stopListening()
                    self.speak("One moment, I am getting my brain ready for the first time. This can take a few minutes.")
                }
            })
        }
        loadSpeechModel()
        panel.orderFrontRegardless()
        isShown = true
        playActivation()
        scheduleListening()

        // Shortcut (default Option + B; the user can change it from the right-click menu)
        hotKey = HotKey { [weak self] in self?.toggle() }
        loadShortcut()
        setupPushToTalk()
        localPlayer.onStopped = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.model.state == .idle else { return }
                self.resumeListening()      // the music ended: BRO goes back to listening by itself
            }
        }
        model.onChangeShortcut = { [weak self] in
            DispatchQueue.main.async { self?.changeShortcut() }
        }
    }

    // Plays one song from this Mac, then carries on with the other songs in random order.
    func playFileThenOthers(_ file: URL) {
        var queue = [file]
        queue += allLocalSongs().filter { $0 != file }.shuffled()
        localPlayer.play(queue: queue)
    }

    // Push-to-talk: BRO listens only while the talk key is held down. Pressing it while BRO talks makes BRO stop talking.
    func setupPushToTalk() {
        guard pushToTalk else { return }
        let key = HoldKey()
        key.onDown = { [weak self] in self?.pttDown() }
        key.onUp = { [weak self] in self?.pttUp() }
        if !key.register(keyCode: talkKeyCode, modifiers: talkKeyMods) {
            print("BRO: could not register the talk key (Option + Space). Another app may be using it.")
        }
        holdKey = key
    }

    func pttDown() {
        guard pushToTalk, isShown, !pttHeld, model.state != .thinking else { return }
        guard stt != nil else { print("BRO: the speech model is still loading."); return }
        pttHeld = true
        pttBuffer = []
        if synth.isSpeaking || pendingSpeech > 0 {
            synth.stopSpeaking(at: .immediate)
            pendingSpeech = 0
        }
        startListening()
        duckMusic()
    }

    func pttUp() {
        guard pttHeld else { return }
        pttHeld = false
        restoreMusic()
        stopListening()
        let audio = pttBuffer
        pttBuffer = []
        if audio.count < 6400 {            // a quick tap (shorter than 0.4 seconds) only stops BRO talking
            resumeListening()
            return
        }
        model.state = .thinking
        transcribe(audio)
    }

    // v48: while the talk key is held, the music gets quieter so the voice is heard clearly. It comes back when the key is let go.
    var duckedSystemVolume: Int? = nil
    var duckedLocal = false

    func duckMusic() {
        if localPlayer.isPlaying {
            localPlayer.setLevel(0.15)
            duckedLocal = true
        } else if duckedSystemVolume == nil {
            let v = currentVolume()
            if v > 15 {
                duckedSystemVolume = v
                setVolume(15)
            }
        }
    }

    func restoreMusic() {
        if duckedLocal {
            localPlayer.setLevel(1.0)
            duckedLocal = false
        }
        if let v = duckedSystemVolume {
            setVolume(v)
            duckedSystemVolume = nil
        }
    }

    func loadShortcut() {
        let ud = UserDefaults.standard
        if let k = ud.object(forKey: "bro.keyCode") as? Int,
           let m = ud.object(forKey: "bro.mods") as? Int,
           let l = ud.string(forKey: "bro.label") {
            shortcutKey = UInt32(k)
            shortcutMods = UInt32(m)
            model.shortcutLabel = l
        }
        if hotKey?.register(keyCode: shortcutKey, modifiers: shortcutMods) != true {
            print("BRO: could not register the shortcut. Another app may be using it. Use right-click > Change shortcut.")
        }
    }

    func changeShortcut() {
        hotKey?.unregister()
        var changed = false
        let alert = NSAlert()
        alert.messageText = "Change BRO shortcut"
        alert.informativeText = "Press the new key combination now.\nIt must include ⌃, ⌥, ⇧ or ⌘.\nCurrent: \(model.shortcutLabel)\nPress Esc to cancel."
        alert.addButton(withTitle: "Cancel")

        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.keyCode == 53 { NSApp.abortModal(); return nil }
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: UInt32 = 0
            if f.contains(.control) { mods |= UInt32(controlKey) }
            if f.contains(.option) { mods |= UInt32(optionKey) }
            if f.contains(.shift) { mods |= UInt32(shiftKey) }
            if f.contains(.command) { mods |= UInt32(cmdKey) }
            if mods == 0 { NSSound.beep(); return nil }
            let code = UInt32(e.keyCode)
            let label = shortcutText(mods, keyName(e))
            if self.hotKey?.register(keyCode: code, modifiers: mods) == true {
                self.shortcutKey = code
                self.shortcutMods = mods
                let ud = UserDefaults.standard
                ud.set(Int(code), forKey: "bro.keyCode")
                ud.set(Int(mods), forKey: "bro.mods")
                ud.set(label, forKey: "bro.label")
                self.model.shortcutLabel = label
                changed = true
                NSApp.abortModal()
            } else {
                alert.informativeText = "\(label) is already used by another app.\nPress a different combination, or Esc to cancel."
                NSSound.beep()
            }
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if let m = monitor { NSEvent.removeMonitor(m) }
        if !changed { hotKey?.register(keyCode: shortcutKey, modifiers: shortcutMods) }
    }

    // The mic starts only after the orb has arrived, and stops as soon as BRO is hidden.
    func scheduleListening() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
            guard let self = self, self.isShown else { return }
            self.startListening()
        }
    }

    func startListening() {
        if holdToTalkNow && !pttHeld { return }       // while BRO plays its own music, the mic starts only when the talk key is held
        guard stt != nil else { loadSpeechModel(); return }
        guard pendingSpeech == 0 else { return }
        MicMonitor.requestAccess { [weak self] ok in
            guard let self = self, self.isShown else { return }
            if self.holdToTalkNow && !self.pttHeld { return }   // the key was already let go
            guard ok else {
                print("BRO: microphone permission is off. Turn it on in System Settings > Privacy & Security > Microphone.")
                return
            }
            do {
                self.endpointer.reset()
                try self.mic.start()
                self.model.state = .listening
            } catch {
                print("BRO: could not start the microphone: \(error)")
            }
        }
    }

    // Loads the Whisper speech model (the first time it downloads about 500 MB).
    func loadSpeechModel() {
        guard stt == nil, !sttLoading else { return }
        sttLoading = true
        print("BRO: loading the speech model (the first time it downloads about 500 MB, please wait)...")
        Task {
            do {
                let pipe = try await WhisperKit(WhisperKitConfig(model: whisperModel))
                self.stt = pipe
                self.sttLoading = false
                print("BRO: speech model ready.")
                if self.isShown { self.startListening() }
            } catch {
                self.sttLoading = false
                print("BRO: could not load the speech model: \(error)")
            }
        }
    }

    var isWaitingForAnswer: Bool { pendingCommand != nil && Date().timeIntervalSince(pendingSince) < 30 }

    func handleChunk(rms: Double, samples: [Float]) {
        model.micLevel = min(1, rms * 8)
        if holdToTalkNow || pttHeld {
            guard pttHeld else { return }
            pttBuffer += samples
            if pttBuffer.count > 16000 * 30 { pttUp() }   // safety stop after 30 seconds
            return
        }
        endpointer.relaxed = isWaitingForAnswer
        guard let sentence = endpointer.feed(rms: rms, samples: samples, now: Date().timeIntervalSinceReferenceDate) else { return }
        stopListening()              // the mic goes off while BRO works on your sentence
        model.state = .thinking
        transcribe(sentence)
    }

    func transcribe(_ samples: [Float]) {
        guard let stt = stt else { return }
        Task { @MainActor in
            var heard = ""
            let lang = "en"
            let waiting = isWaitingForAnswer
            do {
                // English only: the language is fixed, so accented English is never mistaken for Hindi.
                // A short "yes" / "no" answer is padded with silence and heard as plain English (more reliable).
                let opts = (hearHindiAsEnglish && !waiting)
                    ? DecodingOptions(task: .translate, language: nil, detectLanguage: true)
                    : DecodingOptions(task: .transcribe, language: "en", detectLanguage: false)
                var audio = samples
                if waiting {
                    let pad = [Float](repeating: 0, count: 8000)
                    audio = pad + samples + pad
                }
                let results = try await stt.transcribe(audioArray: audio, decodeOptions: opts)
                heard = fixName(results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                print("BRO: transcription failed: \(error)")
            }
            print("BRO heard [\(lang)]: \(heard)")
            let isTag = (heard.hasPrefix("[") && heard.hasSuffix("]")) || (heard.hasPrefix("(") && heard.hasSuffix(")"))
            if !heard.isEmpty && !isTag { chat.add("You", heard) }
            await handleHeard(heard)
        }
    }

    // Runs a voice command (quit BRO, open an app) without asking the AI.
    // Commands that BRO asks "Are you sure?" before running (they cut things off or put the Mac to sleep).
    func needsConfirm(_ cmd: VoiceCommand) -> Bool {
        switch cmd {
        case .sleepMac: return true
        case .wifiPower(let on): return !on
        case .factsClear, .listClear, .forget, .emptyTrash: return true
        case .cancelAlerts(let kind): return kind == "reminder"
        default: return false
        }
    }

    func run(_ cmd: VoiceCommand, lang: String) {
        if needsConfirm(cmd) && !skipConfirm {
            pendingCommand = cmd
            pendingSince = Date()
            speak("Are you sure? Say yes or no.")
            return
        }
        switch cmd {
        case .shutdown:
            print("BRO: shutting down.")
            synth.stopSpeaking(at: .immediate)
            stopListening()
            NSApp.terminate(nil)
        case .time:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "h:mm a"
            let t = f.string(from: Date())
            print("BRO: time \(t)")
            speak("It is \(t).")
        case .date:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "EEEE, d MMMM yyyy"
            let d = f.string(from: Date())
            print("BRO: date \(d)")
            speak("Today is \(d).")
        case .weather(let city):
            Task { @MainActor in
                let report = await fetchWeather(city: city)
                print("BRO says: \(report)")
                if self.isShown { self.speak(report) } else { self.model.state = .idle }
            }
        case .say(let text):
            print("BRO says: \(text)")
            speak(text)
        case .forget:
            history.removeAll()
            UserDefaults.standard.removeObject(forKey: "broHistory")
            speak("Okay, I have forgotten our conversation.")
        case .volumeSet(let n):
            let v = max(0, min(100, n))
            setVolume(v)
            speak("Volume \(v).")
        case .volumeChange(let d):
            let v = max(0, min(100, currentVolume() + d))
            setVolume(v)
            speak("Volume \(v).")
        case .volumeMute(let on):
            runAppleScript("set volume output muted \(on ? "true" : "false")")
            speak(on ? "Muted." : "Unmuted.")
        case .volumeAsk:
            speak("The volume is \(currentVolume()) percent.")
        case .media(let key):
            if localPlayer.isActive {
                switch key {
                case 17: localPlayer.next()
                case 18: localPlayer.previous()
                default: if localPlayer.isPlaying { localPlayer.pause() } else { localPlayer.resume() }
                }
                resumeListening()
            } else if ensureAccessibility() {
                pressMediaKey(key)
                resumeListening()
            } else {
                speak("To control music, please allow BRO in System Settings, Privacy and Security, Accessibility. Then try again.")
            }
        case .playSong(let q, let music):
            localPlayer.stop()
            let site = music ? "YouTube Music" : "YouTube"
            print("BRO: playing '\(q)' on \(site)")
            Task { @MainActor in
                let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
                let base = music ? "https://music.youtube.com" : "https://www.youtube.com"
                if let id = await findBestVideoID(q, song: music), let u = URL(string: base + "/watch?v=" + id) {
                    self.reply("Playing \(q) on \(site).")
                    // YouTube Music opens in a small Brave window (no tabs, no address bar); anything else opens normally
                    let opened = music && openInBraveAppWindow(u)
                    if !opened { NSWorkspace.shared.open(u) }
                } else {
                    let fallback = music ? base + "/search?q=" + enc : base + "/results?search_query=" + enc
                    if let u = URL(string: fallback) { NSWorkspace.shared.open(u) }
                    self.reply("I could not start \(q) by itself, so I opened the \(site) search.")
                }
            }
        case .playRandomSong:
            let all = allLocalSongs().shuffled()
            if all.isEmpty {
                speak("I could not find any songs in your Music folder.")
            } else {
                localPlayer.play(queue: all)
                speak("Playing a random song.")
            }
        case .playAllSongs:
            let all = allLocalSongs()
            if all.isEmpty {
                speak("I could not find any songs in your Music folder.")
            } else {
                localPlayer.play(queue: all)
                speak("Playing all your songs.")
            }
        case .repeatLast:
            if lastSpoken.isEmpty {
                speak("I have not said anything yet.")
            } else {
                speak(lastSpoken)
            }
        case .textBar:
            toggleTextBar()
            resumeListening()
        case .clipboardAI(let instruction):
            if let c = NSPasteboard.general.string(forType: .string), !c.isEmpty {
                let clip = String(c.prefix(3000))
                Task { @MainActor in
                    await self.aiTextTask("\(instruction):\n\n\(clip)", copyResult: instruction.contains("reply with only"))
                }
            } else {
                speak("Your clipboard is empty.")
            }
        case .orbColor(let name):
            setOrbColor(name)
            speak(name == "default" ? "Done. The orb has its normal colours again." : "Done. The orb is now \(name).")
        case .writeAI(let request):
            Task { @MainActor in
                await self.aiTextTask(request, copyResult: true)
            }
        case .factAdd(let fact):
            var facts = loadFacts()
            if !facts.contains(where: { $0.lowercased() == fact.lowercased() }) { facts.append(String(fact.prefix(200))) }
            saveFacts(facts)
            speak("Okay, I will remember that.")
        case .factsRead:
            let facts = loadFacts()
            if facts.isEmpty {
                speak("You have not asked me to remember anything yet.")
            } else {
                speak("I remember \(facts.count) \(facts.count == 1 ? "thing" : "things"): " + facts.joined(separator: ". ") + ".")
            }
        case .factsClear:
            saveFacts([])
            speak("Done. I forgot everything you asked me to remember.")
        case .loginItem(let on):
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                speak(on ? "Done. I will start when you log in. If it does not work, check Login Items in System Settings." : "Done. I will not start at login any more.")
            } catch {
                print("BRO: login item problem: \(error)")
                speak("Sorry, I could not change that. You can add me yourself in System Settings, General, Login Items.")
            }
        case .listAdd(let items):
            var list = UserDefaults.standard.stringArray(forKey: "broList") ?? []
            for i in items where !list.contains(where: { $0.lowercased() == i.lowercased() }) {
                list.append(i)
            }
            UserDefaults.standard.set(list, forKey: "broList")
            speak("Added \(items.joined(separator: " and ")) to your list.")
        case .listRead:
            let list = UserDefaults.standard.stringArray(forKey: "broList") ?? []
            if list.isEmpty {
                speak("Your list is empty.")
            } else {
                speak("Your list has \(list.count) \(list.count == 1 ? "item" : "items"): " + list.joined(separator: ", ") + ".")
            }
        case .listRemove(let item):
            var list = UserDefaults.standard.stringArray(forKey: "broList") ?? []
            let before = list.count
            list.removeAll { $0.lowercased().contains(item.lowercased()) }
            UserDefaults.standard.set(list, forKey: "broList")
            speak(list.count < before ? "Removed \(item) from your list." : "I could not find \(item) on your list.")
        case .listClear:
            UserDefaults.standard.set([String](), forKey: "broList")
            speak("Your list is cleared.")
        case .currency(let value, let from, let to):
            Task { @MainActor in
                let r = await fetchCurrency(value, from, to)
                self.reply(r)
            }
        case .crypto(let coin):
            Task { @MainActor in
                let r = await fetchCrypto(coin)
                self.reply(r)
            }
        case .stopwatch(let action):
            switch action {
            case "start":
                stopwatchStart = Date()
                speak("Stopwatch started.")
            case "stop":
                if let s = stopwatchStart {
                    speak("Stopped at \(durationText(Int(Date().timeIntervalSince(s)))).")
                    stopwatchStart = nil
                } else {
                    speak("The stopwatch is not running.")
                }
            case "reset":
                stopwatchStart = nil
                speak("Stopwatch reset.")
            default:
                if let s = stopwatchStart {
                    speak("\(durationText(Int(Date().timeIntervalSince(s)))) so far.")
                } else {
                    speak("The stopwatch is not running.")
                }
            }
        case .remindRepeat(let task, let date, let rule):
            alerts.append(BroAlert(id: UUID().uuidString, kind: "reminder", fire: date,
                                   message: "Reminder: \(task).", repeatRule: rule))
            saveAlerts()
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "EEEE"
            let when = rule == "daily" ? "every day" : "every \(f.string(from: date))"
            speak("Okay, I will remind you \(when) at \(clockText(date)) to \(task).")
        case .listAlerts(let kind):
            let mine = alerts.filter { $0.kind == kind }.sorted { $0.fire < $1.fire }
            if mine.isEmpty {
                speak("You have no \(kind)s.")
            } else {
                var parts: [String] = []
                for a in mine.prefix(5) {
                    let rep = a.repeatRule == "daily" ? " every day" : (a.repeatRule == "weekly" ? " every week" : "")
                    if kind == "reminder" {
                        parts.append(a.message.replacingOccurrences(of: "Reminder: ", with: "") + " at " + clockText(a.fire) + rep)
                    } else {
                        parts.append(clockText(a.fire))
                    }
                }
                speak("You have \(mine.count) \(kind)\(mine.count == 1 ? "" : "s"): " + parts.joined(separator: ". ") + ".")
            }
        case .goTo(let name):
            let key = normScalars(name.replacingOccurrences(of: " ", with: ""))
            if let site = siteAliases[key] {
                openAddress(site[1])
                speak("Opening \(site[0]).")
            } else {
                let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                openAddress("https://duckduckgo.com/?q=" + enc)
                speak("Searching for \(name).")
            }
        case .briefing:
            Task { @MainActor in
                let text = await self.buildBriefing()
                self.reply(text)
            }
        case .pageAI(let instruction):
            Task { @MainActor in
                guard let page = await readBrowserPage() else {
                    self.reply("I could not read the page. Open it in Brave, Chrome or Safari first. If it still fails, in the browser menu choose View, Developer, Allow JavaScript from Apple Events.")
                    return
                }
                if page.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
                    self.reply("I could not get the text of this page. In the browser menu choose View, Developer, Allow JavaScript from Apple Events, then try again.")
                    return
                }
                await self.think("\(instruction). Page title: \(page.title). Page text: \(page.text)", remember: false)
            }
        case .pageRead:
            Task { @MainActor in
                guard let page = await readBrowserPage() else {
                    self.reply("I could not read the page. Open it in Brave, Chrome or Safari first. If it still fails, in the browser menu choose View, Developer, Allow JavaScript from Apple Events.")
                    return
                }
                self.reply(page.title + ". " + String(page.text.prefix(500)))
            }
        case .keys(let script):
            if runAppleScript(script) != nil {
                resumeListening()
            } else {
                speak("I could not press the keys. Please allow BRO in System Settings, Privacy and Security, Accessibility.")
            }
        case .pomodoro:
            addAlert("timer", Date().addingTimeInterval(25 * 60), "Focus time is over. Take a five minute break.")
            addAlert("timer", Date().addingTimeInterval(30 * 60), "Break is over. Back to work.")
            speak("Pomodoro started. Focus for 25 minutes.")
        case .speechRate(let step):
            var r = currentSpeechRate()
            if step == 0 { r = speechRate } else { r = max(0.3, min(0.7, r + Float(step) * 0.1)) }
            UserDefaults.standard.set(r, forKey: "broRate")
            speak(step == 0 ? "Back to my normal speed." : (step < 0 ? "Okay, I will talk slower." : "Okay, I will talk faster."))
        case .sysInfo(let what):
            switch what {
            case "uptime":
                let out = runTool("/usr/sbin/sysctl", ["-n", "kern.boottime"])
                if let r = out.range(of: "sec = [0-9]+", options: .regularExpression),
                   let boot = Double(out[r].dropFirst(6)) {
                    let secs = Int(Date().timeIntervalSince1970 - boot)
                    let days = secs / 86400
                    let rest = secs % 86400
                    let text = days > 0 ? "\(days) \(days == 1 ? "day" : "days") and \(durationText(rest))" : durationText(rest)
                    speak("Your Mac has been on for \(text).")
                } else {
                    speak("I could not read that.")
                }
            case "memory":
                let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000).rounded())
                var text = "Your Mac has \(gb) gigabytes of memory."
                let mp = runTool("/usr/bin/memory_pressure", [])
                if let r = mp.range(of: "free percentage: [0-9]+", options: .regularExpression) {
                    let pct = String(mp[r]).replacingOccurrences(of: "free percentage: ", with: "")
                    text += " About \(pct) percent of it is free."
                }
                speak(text)
            default:
                let local = runTool("/usr/sbin/ipconfig", ["getifaddr", "en0"]).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    var publicIP = ""
                    if let url = URL(string: "https://api.ipify.org") {
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 4
                        if let result = try? await URLSession.shared.data(for: req) {
                            publicIP = String(decoding: result.0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    var parts: [String] = []
                    if !local.isEmpty { parts.append("Your Mac's address on this network is \(local).") }
                    if !publicIP.isEmpty { parts.append("Your public address is \(publicIP).") }
                    self.reply(parts.isEmpty ? "I could not find an address. Are you online?" : parts.joined(separator: " "))
                }
            }
        case .topApps(let kind):
            DispatchQueue.global().async {
                let report = topAppsReport(kind)
                DispatchQueue.main.async { self.reply(report) }
            }
        case .kbLightSet(let p):
            setKeyboardLight(p)
        case .kbLightOn:
            let saved = UserDefaults.standard.double(forKey: "broKbLevel")
            setKeyboardLight(saved > 0.03 ? Int((saved * 100).rounded()) : 100)
        case .kbLightChange(let d):
            let cur = Int(((KeyboardLight.shared.get() ?? 0.5) * 100).rounded())
            setKeyboardLight(cur + d)
        case .kbLightAuto:
            if KeyboardLight.shared.setAuto(true) {
                reply("Done. The keyboard light is automatic again.")
            } else {
                reply("Sorry, I could not do that on this Mac.")
            }
        case .emptyTrash:
            if runAppleScript("tell application \"Finder\" to empty trash") != nil {
                speak("The trash is empty.")
            } else {
                speak("I could not empty the trash. Please allow BRO to control Finder in System Settings, Privacy and Security, Automation.")
            }
        case .closeSong:
            if localPlayer.isActive {
                localPlayer.stop()
                speak("Song closed.")
            } else {
                speak("No song is playing inside BRO.")
            }
        case .stopMusic:
            if localPlayer.isActive {
                localPlayer.stop()
                speak("Music stopped.")
            } else {
                run(.media(16), lang: lang)
            }
        case .brightnessChange(let n):
            if let cur = getScreenBrightness(), setScreenBrightness(cur + Float(n) * 0.0625) {
                let now = getScreenBrightness().map { Int(($0 * 100).rounded()) } ?? 0
                reply("Brightness is now \(now) percent.")
            } else {
                let code = n > 0 ? 144 : 145
                let times = abs(n)
                DispatchQueue.global().async {
                    _ = runTool("/usr/bin/osascript", ["-e", "tell application \"System Events\"", "-e", "repeat \(times) times",
                                                       "-e", "key code \(code)", "-e", "delay 0.06", "-e", "end repeat", "-e", "end tell"])
                    DispatchQueue.main.async { self.reply(n > 0 ? "Brighter." : "Dimmer.") }
                }
            }
        case .brightnessSet(let percent):
            if setScreenBrightness(Float(percent) / 100) {
                let now = getScreenBrightness().map { Int(($0 * 100).rounded()) } ?? percent
                reply("Brightness is now \(now) percent.")
            } else {
                let ups = Int((Double(percent) / 100.0 * 16.0).rounded())
                DispatchQueue.global().async {
                    var script = ["-e", "tell application \"System Events\"", "-e", "repeat 20 times", "-e", "key code 145",
                                  "-e", "delay 0.06", "-e", "end repeat"]
                    if ups > 0 {
                        script += ["-e", "repeat \(ups) times", "-e", "key code 144", "-e", "delay 0.06", "-e", "end repeat"]
                    }
                    script += ["-e", "end tell"]
                    _ = runTool("/usr/bin/osascript", script)
                    DispatchQueue.main.async { self.reply("Brightness is now about \(percent) percent.") }
                }
            }
        case .calendarToday:
            DispatchQueue.global().async {
                let script = ["-e", "set d0 to current date", "-e", "set time of d0 to 0", "-e", "set d1 to d0 + 1 * days",
                              "-e", "set out to \"\"",
                              "-e", "tell application \"Calendar\"",
                              "-e", "repeat with c in calendars",
                              "-e", "set evs to (every event of c whose start date >= d0 and start date < d1)",
                              "-e", "repeat with e in evs",
                              "-e", "set out to out & (summary of e) & \" at \" & (time string of (start date of e)) & \";\"",
                              "-e", "end repeat",
                              "-e", "end repeat",
                              "-e", "end tell",
                              "-e", "return \"OK|\" & out"]
                let out = runTool("/usr/bin/osascript", script).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard out.hasPrefix("OK|") else {
                        self.reply("I could not read your calendar. Please allow BRO to control Calendar in System Settings, Privacy and Security, Automation.")
                        return
                    }
                    let events = out.dropFirst(3).split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if events.isEmpty {
                        self.reply("You have nothing on your calendar today.")
                    } else {
                        let shown = events.prefix(5).joined(separator: ", ")
                        self.reply("You have \(events.count) \(events.count == 1 ? "event" : "events") today: \(shown).")
                    }
                }
            }
        case .runShortcut(let name):
            DispatchQueue.global().async {
                func squash(_ t: String) -> String {
                    String(t.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) })
                }
                let names = runTool("/usr/bin/shortcuts", ["list"]).split(separator: "\n").map { String($0) }
                let want = squash(name)
                let found = names.first(where: { squash($0) == want }) ?? names.first(where: { !want.isEmpty && squash($0).contains(want) })
                guard let exact = found else {
                    DispatchQueue.main.async { self.reply("I could not find a shortcut called \(name).") }
                    return
                }
                _ = runTool("/usr/bin/shortcuts", ["run", exact])
                DispatchQueue.main.async { self.reply("Done. I ran \(exact).") }
            }
        case .openFolder(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            speak("Opening the folder.")
        case .wifiPower(let on):
            DispatchQueue.global().async {
                let ports = runTool("/usr/sbin/networksetup", ["-listallhardwareports"])
                var device = "en0"
                var seenWifi = false
                for line in ports.split(separator: "\n") {
                    let text = String(line)
                    if text.contains("Hardware Port: Wi-Fi") { seenWifi = true }
                    else if seenWifi && text.hasPrefix("Device:") {
                        device = text.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                _ = runTool("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"])
                DispatchQueue.main.async { self.reply(on ? "Wi-Fi is on." : "Wi-Fi is off.") }
            }
        case .playLocalSong(let q):
            if q.isEmpty {
                speak("Tell me which song to play from your Mac.")
            } else if let file = findLocalSong(q) {
                print("BRO: playing local file \(file.path)")
                playFileThenOthers(file)
                speak("Playing \(q) from your Mac.")
            } else {
                print("BRO: no local file matched '\(q)' in \(localMusicFolder)")
                speak("I could not find \(q) in your Music folder.")
            }
        case .playAnySong(let q):
            if let file = findLocalSong(q) {
                print("BRO: playing local file \(file.path)")
                playFileThenOthers(file)
                speak("Playing \(q) from your Mac.")
            } else {
                run(.playSong(q, true), lang: lang)
            }
        case .closeYTMusic:
            if let app = findRunningApp("youtube music") {
                print("BRO: closing YouTube Music app")
                _ = app.terminate()
                speak("Closing YouTube Music.")
            } else if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.brave.Browser" }) {
                DispatchQueue.global().async {
                    let script = ["-e", "tell application \"Brave Browser\"",
                                  "-e", "set n to 0",
                                  "-e", "repeat with i from (count of windows) to 1 by -1",
                                  "-e", "if (title of active tab of window i) contains \"YouTube Music\" then",
                                  "-e", "close window i",
                                  "-e", "set n to n + 1",
                                  "-e", "end if",
                                  "-e", "end repeat",
                                  "-e", "return n",
                                  "-e", "end tell"]
                    let out = runTool("/usr/bin/osascript", script).trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        if let n = Int(out) {
                            self.reply(n > 0 ? "Closed YouTube Music." : "YouTube Music is not open.")
                        } else {
                            self.reply("I could not close it. Please allow BRO to control Brave Browser in System Settings, Privacy and Security, Automation.")
                        }
                    }
                }
            } else {
                speak("YouTube Music is not open.")
            }
        case .search(let q, let yt):
            let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            let address: String
            if yt {
                address = q.isEmpty ? "https://www.youtube.com" : "https://www.youtube.com/results?search_query=" + enc
            } else {
                address = "https://www.google.com/search?q=" + enc
            }
            openAddress(address)
            speak(yt ? (q.isEmpty ? "Opening YouTube." : "Searching YouTube for \(q).") : "Searching Google for \(q).")
        case .timer(let secs):
            addAlert("timer", Date().addingTimeInterval(Double(secs)), "Your \(durationText(secs)) timer is done.")
            speak("Timer set for \(durationText(secs)).")
        case .alarm(let date):
            addAlert("alarm", date, "It is \(clockText(date)). Your alarm is going off.")
            speak("Alarm set for \(clockText(date)).")
        case .cancelAlerts(let kind):
            let count = alerts.filter { $0.kind == kind }.count
            alerts.removeAll { $0.kind == kind }
            saveAlerts()
            speak(count == 0 ? "You have no \(kind)s set." : "Cancelled.")
        case .timeLeft:
            let timers = alerts.filter { $0.kind == "timer" }
            if let t = timers.min(by: { $0.fire < $1.fire }) {
                let left = max(0, Int(t.fire.timeIntervalSinceNow))
                speak("\(durationText(left)) left.")
            } else {
                speak("You have no timers running.")
            }
        case .remind(let task, let date):
            addAlert("reminder", date, "Reminder: \(task).")
            addToAppleReminders(task, date)
            speak("Okay, I will remind you to \(task) at \(clockText(date)).")
        case .note(let body):
            if body.isEmpty {
                speak("What should I write? Say for example: take a note, buy milk.")
            } else {
                let nice = String(body.prefix(1)).uppercased() + String(body.dropFirst())
                let ok = runAppleScript("tell application \"Notes\" to make new note with properties {body:\"\(asEscape(nice))\"}")
                speak(ok != nil ? "Note saved." : "I could not save the note. Please allow BRO to control Notes in System Settings, Privacy and Security, Automation.")
            }
        case .battery:
            let out = runTool("/usr/bin/pmset", ["-g", "batt"])
            var pct = ""
            if let r = out.range(of: "[0-9]+%", options: .regularExpression) {
                pct = String(out[r]).replacingOccurrences(of: "%", with: "")
            }
            if pct.isEmpty {
                speak("I could not read the battery.")
            } else {
                var state = "on battery"
                if out.contains("discharging") {
                    state = "on battery"
                } else if out.contains("finishing charge") || out.contains("charged") {
                    state = "fully charged"
                } else if out.contains("not charging") {
                    state = "plugged in but not charging"
                } else if out.contains("charging") {
                    state = "charging"
                }
                speak("Battery is at \(pct) percent, \(state).")
            }
        case .wifi:
            Task { @MainActor in
                let power = runTool("/usr/sbin/networksetup", ["-getairportpower", "en0"])
                let wifiOn = power.contains("On")
                var online = false
                if let url = URL(string: "https://www.apple.com/library/test/success.html") {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 5
                    if let result = try? await URLSession.shared.data(for: req),
                       (result.1 as? HTTPURLResponse)?.statusCode == 200 {
                        online = true
                    }
                }
                if online {
                    self.reply("Wi-Fi is on and the internet is working.")
                } else if wifiOn {
                    self.reply("Wi-Fi is on, but I cannot reach the internet.")
                } else {
                    self.reply("Wi-Fi is off.")
                }
            }
        case .disk:
            let url = URL(fileURLWithPath: "/")
            if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let bytes = v.volumeAvailableCapacityForImportantUsage {
                let gb = Int((Double(bytes) / 1_000_000_000).rounded())
                speak("You have \(gb) gigabytes free.")
            } else {
                speak("I could not read the storage.")
            }
        case .clipboard:
            if let c = NSPasteboard.general.string(forType: .string), !c.isEmpty {
                let short = c.count > 300 ? String(c.prefix(300)) + "..." : c
                speak("Your clipboard says: \(short)")
            } else {
                speak("Your clipboard is empty.")
            }
        case .darkMode(let mode):
            let script: String
            if mode < 0 {
                script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
            } else {
                script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(mode == 1 ? "true" : "false")"
            }
            if runAppleScript(script) != nil {
                speak(mode < 0 ? "Done." : (mode == 1 ? "Dark mode on." : "Light mode on."))
            } else {
                speak("I could not change it. Please allow BRO to control System Events in System Settings, Privacy and Security, Automation.")
            }
        case .lockScreen:
            // Control + Command + Q is the Mac's own "Lock Screen" shortcut (needs BRO's Accessibility permission)
            if runAppleScript("tell application \"System Events\" to keystroke \"q\" using {control down, command down}") == nil {
                print("BRO: could not press the lock shortcut, only turning the screen off")
                _ = runTool("/usr/bin/pmset", ["displaysleepnow"])
            }
            resumeListening()
        case .sleepMac:
            speak("Going to sleep.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                _ = runTool("/usr/bin/pmset", ["sleepnow"])
            }
        case .screenshot:
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            // Saved in Pictures > BRO Screenshots (the Desktop is protected and synced with iCloud, which made it fail)
            let folder = NSHomeDirectory() + "/Pictures/BRO Screenshots"
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let path = folder + "/BRO-Screenshot-\(f.string(from: Date())).png"
            // BRO's own orb and typing window are hidden for a moment, so they are not in the picture
            let orbWasVisible = panel.isVisible
            let textWasVisible = textPanel?.isVisible ?? false
            if orbWasVisible { panel.orderOut(nil) }
            if textWasVisible { textPanel?.orderOut(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                _ = runTool("/usr/sbin/screencapture", ["-x", path])
                if orbWasVisible { self.panel.orderFrontRegardless() }
                if textWasVisible { self.textPanel?.orderFront(nil) }
                if FileManager.default.fileExists(atPath: path) {
                    self.speak("Screenshot saved in your Pictures folder.")
                } else if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                    self.speak("I need Screen Recording permission. In System Settings, Privacy and Security, Screen Recording, switch BRO off and on, then quit and reopen BRO.")
                } else {
                    self.speak("Screen Recording is allowed, but I could not save the screenshot. Please try again.")
                }
            }
        case .news(let topic):
            Task { @MainActor in
                let r = await fetchHeadlines(topic: topic)
                self.reply(r)
            }
        case .define(let word):
            Task { @MainActor in
                let r = await fetchDefinition(word)
                self.reply(r)
            }
        case .typeText(let body):
            guard ensureAccessibility() else {
                speak("To type for you, please allow BRO in System Settings, Privacy and Security, Accessibility. Then try again.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                typeString(body)
                self?.resumeListening()
            }
        case .openIn(let name, let browser):
            let key = normScalars(name.replacingOccurrences(of: " ", with: ""))
            if let site = siteAliases[key] {
                _ = runTool("/usr/bin/open", ["-a", browser, site[1]])
                speak("Opening \(site[0]) in \(browser).")
            } else {
                let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                _ = runTool("/usr/bin/open", ["-a", browser, "https://www.google.com/search?q=" + enc])
                speak("I do not know that website, so I am searching for \(name) in \(browser).")
            }
        case .closeApp(let name):
            if let app = findRunningApp(name) {
                let shown = app.localizedName ?? name
                print("BRO: closing \(shown)")
                if !app.terminate() { print("BRO: \(shown) did not close (it may be asking to save something).") }
                speak(lang == "hi" ? "\(shown) बंद कर रहा हूँ।" : "Closing \(shown).")
            } else {
                print("BRO: '\(name)' is not open")
                speak(lang == "hi" ? "\(name) अभी खुला नहीं है।" : "\(name) is not open.")
            }
        case .openApp(let name):
            let siteKey = normScalars(name.replacingOccurrences(of: " ", with: ""))
            if let b = browserNames[siteKey] {
                lastBrowser = b
                lastBrowserTime = Date()
            }
            if appAliases[siteKey] == nil, siteKey != "youtubemusic", siteKey != "ytmusic", let site = siteAliases[siteKey], let u = URL(string: site[1]) {
                print("BRO: opening \(site[0]) in the browser")
                openAddress(site[1])
                speak("Opening \(site[0]).")
            } else if let url = findApp(name) {
                let shown = url.deletingPathExtension().lastPathComponent
                if shown == "Finder" {
                    // Finder is always running, so "open Finder" means: show a new Finder window
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
                    speak("Opening Finder.")
                    return
                }
                print("BRO: opening \(shown)")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error = error { print("BRO: could not open \(shown): \(error.localizedDescription)") }
                }
                speak(lang == "hi" ? "\(shown) खोल रहा हूँ।" : "Opening \(shown).")
            } else {
                if let site = siteAliases[siteKey], let u = URL(string: site[1]) {
                    print("BRO: no app found, opening \(site[0]) in the browser")
                    openAddress(site[1])
                    speak("I could not find the app, so I am opening \(site[0]) in the browser.")
                    return
                }
                print("BRO: no app found for '\(name)'")
                speak(lang == "hi" ? "मुझे \(name) नाम का ऐप नहीं मिला।" : "I could not find an app called \(name).")
            }
        }
    }

    // Sets the keyboard backlight to a percent. First the direct way; if that fails, the keyboard-light keys are pressed.
    func setKeyboardLight(_ pct: Int) {
        let p = max(0, min(100, pct))
        let kl = KeyboardLight.shared
        if p == 0, let c = kl.get(), c > 0.03 { UserDefaults.standard.set(Double(c), forKey: "broKbLevel") }
        kl.setAuto(false)
        if kl.set(Float(p) / 100) {
            reply(p == 0 ? "Keyboard light is off." : "Keyboard light is now \(p) percent.")
            return
        }
        print("BRO: direct keyboard light control did not work, trying the keyboard light keys")
        guard ensureAccessibility() else {
            speak("To control the keyboard light, please allow BRO in System Settings, Privacy and Security, Accessibility. Then try again.")
            return
        }
        Task { @MainActor in
            for _ in 0..<17 {
                pressMediaKey(22)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            let ups = Int((Double(p) / 100.0 * 16.0).rounded())
            for _ in 0..<ups {
                pressMediaKey(21)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            self.reply(p == 0 ? "Keyboard light is off." : "Keyboard light is now about \(p) percent.")
        }
    }

    func finishedSpeaking() {
        pendingSpeech = max(0, pendingSpeech - 1)
        if pendingSpeech == 0 { resumeListening() }
    }

    // Speaks a result that arrived later (news, definitions, weather) if BRO is still on screen.
    func reply(_ text: String) {
        print("BRO says: \(text)")
        if isShown { speak(text) } else { chat.add("BRO", text); model.state = .idle }
    }

    // MARK: Timers, alarms and reminders (kept by BRO, saved so they survive a restart)

    var alerts: [BroAlert] = []
    var alertTicker: Timer?

    func loadAlerts() {
        if let d = UserDefaults.standard.data(forKey: "broAlerts"),
           let a = try? JSONDecoder().decode([BroAlert].self, from: d) {
            alerts = a
        }
        alertTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkAlerts()
        }
    }

    func saveAlerts() {
        if let d = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(d, forKey: "broAlerts")
        }
    }

    func addAlert(_ kind: String, _ fire: Date, _ message: String) {
        alerts.append(BroAlert(id: UUID().uuidString, kind: kind, fire: fire, message: message))
        saveAlerts()
    }

    func checkAlerts() {
        let now = Date()
        var keep: [BroAlert] = []
        var due: [BroAlert] = []
        for a in alerts {
            if a.fire <= now {
                due.append(a)
                if let r = a.repeatRule {
                    var next = a.fire
                    let step = (r == "weekly") ? 7 : 1
                    while next <= now {
                        next = Calendar.current.date(byAdding: .day, value: step, to: next) ?? now.addingTimeInterval(86400)
                    }
                    var b = a
                    b.fire = next
                    keep.append(b)
                }
            } else {
                keep.append(a)
            }
        }
        if due.isEmpty { return }
        alerts = keep
        saveAlerts()
        fireAlert(due.map { $0.message }.joined(separator: " "))
    }

    func fireAlert(_ text: String) {
        NSSound(named: NSSound.Name("Glass"))?.play()
        print("BRO says: \(text)")
        stopListening()
        if !isShown { showBRO() }
        speak(text)
    }

    // Also puts the reminder into the Mac's Reminders app (needs a one-time Allow).
    func addToAppleReminders(_ task: String, _ date: Date) {
        let secs = max(5, Int(date.timeIntervalSinceNow))
        runAppleScript("tell application \"Reminders\" to make new reminder with properties {name:\"\(asEscape(task))\", remind me date:((current date) + \(secs))}")
    }

    // MARK: v29 helpers inside the app

    // Opens a web address in the browser BRO opened a moment ago (for "open Brave and search ..."), else in the default browser.
    func openAddress(_ address: String) {
        guard let u = URL(string: address) else { return }
        if let b = lastBrowser, Date().timeIntervalSince(lastBrowserTime) < 180 {
            _ = runTool("/usr/bin/open", ["-a", b, address])
        } else {
            NSWorkspace.shared.open(u)
        }
    }

    // Everything BRO hears (or you type) goes through here.
    func handleHeard(_ heard: String) async {
        let tagCheck = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if ((tagCheck.hasPrefix("[") && tagCheck.hasSuffix("]")) || (tagCheck.hasPrefix("(") && tagCheck.hasSuffix(")")))
            && tagCheck.rangeOfCharacter(from: .decimalDigits) == nil {
            print("BRO: ignored a sound tag: \(tagCheck)")
            resumeListening()
            return
        }
        if let pending = pendingCommand {
            if Date().timeIntervalSince(pendingSince) >= 30 {
                pendingCommand = nil
            } else {
                let words = commandWords(heard)
                let wset = Set(words)
                let yes: Set<String> = ["yes", "yeah", "yea", "yep", "yup", "ya", "yas", "yess", "sure", "ok", "okay", "confirm",
                                        "confirmed", "correct", "haan", "han", "affirmative", "proceed"]
                let no: Set<String> = ["no", "noo", "nope", "nah", "nay", "know", "now", "cancel", "cancelled", "canceled", "dont",
                                       "stop", "nahi", "nahin", "na", "wait", "never", "negative"]
                let noise: Set<String> = ["thank", "thanks", "you", "bye", "uh", "um", "hmm", "mm", "oh", "ah", "the"]
                if words.count <= 4 && !wset.isDisjoint(with: no) {
                    pendingCommand = nil
                    reply("Okay, cancelled.")
                    return
                }
                if words.count <= 4 && !wset.isDisjoint(with: yes) {
                    pendingCommand = nil
                    skipConfirm = true
                    run(pending, lang: "en")
                    skipConfirm = false
                    return
                }
                if words.isEmpty || wset.isSubset(of: noise) {
                    // nothing clear was heard: keep waiting for the answer
                    resumeListening()
                    return
                }
                pendingCommand = nil      // a different sentence: the question is dropped and the sentence is handled as normal
            }
        }
        if heard.count < 2 {
            resumeListening()
            return
        }
        if let chain = parseChain(heard) {
            runChain(chain, lang: "en")
        } else if let cmd = parseCommand(heard) {
            run(cmd, lang: "en")
        } else if looksLikeAction(heard) {
            // BRO does not know this command, so it says so instead of letting the AI pretend it did it
            print("BRO: no command matched, not sending an action request to the AI")
            if smartPrefilter(heard), let cmd = await smartCommand(heard) {
                run(cmd, lang: "en")
            } else {
                reply("Sorry, I do not know how to do that yet.")
            }
        } else if useWikipedia, let topic = wikiTopic(heard) {
            if let answer = await fetchWikipedia(topic) {
                print("BRO: answered from Wikipedia")
                history.append(["role": "user", "content": heard])
                history.append(["role": "assistant", "content": answer])
                if history.count > 8 { history.removeFirst(history.count - 8) }
                UserDefaults.standard.set(history, forKey: "broHistory")
                reply(answer)
            } else {
                await think(heard)       // no internet or no article: the local AI answers
            }
        } else if smartPrefilter(heard), let cmd = await smartCommand(heard) {
            run(cmd, lang: "en")
        } else {
            await think(heard)
        }
    }

    // Several commands in one sentence. All but the last stay quiet, the last one speaks.
    func runChain(_ cmds: [VoiceCommand], lang: String) {
        for (i, c) in cmds.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.7) { [weak self] in
                guard let self = self else { return }
                self.quietSpeech = i < cmds.count - 1
                self.run(c, lang: lang)
                self.quietSpeech = false
                if i == cmds.count - 1, !self.chainNotes.isEmpty {   // the last command said nothing itself
                    let t = self.chainNotes.joined(separator: " ")
                    self.chainNotes = []
                    self.speak(t)
                }
            }
        }
    }

    // MARK: Typing window

    func makeTextPanel() {
        let size = NSSize(width: 540, height: 280)
        let p = TextPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: TextBarView(chat: chat, onClose: { [weak self] in self?.textPanel?.orderOut(nil) }))
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 100))
        }
        textPanel = p
    }

    func toggleTextBar() {
        if textPanel == nil { makeTextPanel() }
        guard let p = textPanel else { return }
        if p.isVisible {
            p.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
        }
    }

    // A message typed in the window: BRO writes the answer there and also says it out loud.
    func submitTyped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        chat.add("You", t)
        if !isShown { showBRO() }
        synth.stopSpeaking(at: .immediate)
        pendingSpeech = 0
        stopListening()
        model.state = .thinking
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.stopListening()
            await self.handleHeard(t)
        }
    }

    // MARK: Battery warning

    func checkBattery() {
        guard batteryWarnings else { return }
        DispatchQueue.global().async {
            let out = runTool("/usr/bin/pmset", ["-g", "batt"])
            DispatchQueue.main.async { self.handleBattery(out) }
        }
    }

    func handleBattery(_ out: String) {
        guard let r = out.range(of: "[0-9]+%", options: .regularExpression),
              let pct = Int(out[r].dropLast()) else { return }
        let discharging = out.contains("discharging")
        if !discharging || pct > 25 {
            batteryWarned.removeAll()
            return
        }
        let hit = [20, 10, 5].filter { pct <= $0 && !batteryWarned.contains($0) }
        if !hit.isEmpty {
            for h in hit { batteryWarned.insert(h) }
            fireAlert("Battery is at \(pct) percent. Please plug in the charger.")
        }
    }

    // MARK: Morning briefing

    func buildBriefing() async -> String {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let greet = hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "EEEE, d MMMM"
        var parts: [String] = ["\(greet), \(userName). It is \(clockText(now)) on \(df.string(from: now))."]
        async let weather = fetchWeather(city: nil)
        async let news = fetchHeadlines(topic: nil)
        let cal = await Task.detached { calendarTodaySummary() }.value
        parts.append(await weather)
        if let c = cal { parts.append(c) }
        let todays = alerts.filter { $0.kind == "reminder" && Calendar.current.isDateInToday($0.fire) }
        if !todays.isEmpty { parts.append("You have \(todays.count) \(todays.count == 1 ? "reminder" : "reminders") today.") }
        let list = UserDefaults.standard.stringArray(forKey: "broList") ?? []
        if !list.isEmpty { parts.append("Your list has \(list.count) \(list.count == 1 ? "item" : "items").") }
        parts.append(await news)
        return parts.joined(separator: " ")
    }

    func resumeListening() {
        if waitingForBrain { model.state = .thinking; return }
        if holdToTalkNow { if !pttHeld { model.state = .idle }; return }   // BRO is playing its own music: the mic opens only while the talk key is held
        if isShown { startListening() } else { model.state = .idle }
    }

    // Sends the sentence to BRO's built-in brain (Brain.swift) and speaks the answer. No Jan, works offline.
    func think(_ text: String, remember: Bool = true) async {
        if remember {
            history.append(["role": "user", "content": text])
            if history.count > 8 { history.removeFirst(history.count - 8) }
        }
        let asked: [[String: String]] = remember ? history : [["role": "user", "content": text]]

        waitingForBrain = true          // the microphone stays closed while the brain works
        var reply = ""
        do {
            reply = try await Brain.shared.reply(system: makeSystemPrompt(), history: asked, onSlowLoad: { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, self.isShown else { return }
                    self.stopListening()
                    self.speak("One moment, I am getting my brain ready.")
                }
            })
        } catch {
            print("BRO: the brain had a problem: \(error)")
        }
        waitingForBrain = false

        while let r = reply.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) { reply.removeSubrange(r) }
        reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty {
            if remember, !history.isEmpty { history.removeLast() }
            if isShown { speak("Sorry, say that again.") } else { model.state = .idle }
            return
        }
        if remember {
            history.append(["role": "assistant", "content": reply])
            UserDefaults.standard.set(history, forKey: "broHistory")
        }
        print("BRO says: \(reply)")
        if isShown { speak(reply) } else { model.state = .idle }
    }

    // Smart commands: the brain may only PICK a number from this short, harmless list. It never runs anything itself.
    // Anything else (or a wrong answer) means "no command", and BRO carries on as before.
    func smartCommand(_ text: String) async -> VoiceCommand? {
        let system = "You pick one command for a Mac voice assistant. Reply with ONLY one number from this list, or 0 if the sentence is not clearly one of these requests. If unsure, reply 0. No other words. 1 = make the screen brighter. 2 = make the screen dimmer or darker. 3 = turn the volume up. 4 = turn the volume down. 5 = mute the sound. 6 = unmute the sound. 7 = turn on dark mode. 8 = turn on light mode. 9 = play or pause the music. 10 = next song. 11 = previous song. 12 = tell the weather. 13 = tell the time. 14 = tell the date. 15 = tell the battery level. 16 = read the news headlines. 17 = take a screenshot. 18 = lock the screen. 19 = turn the keyboard light on. 20 = turn the keyboard light off. 21 = make the keyboard light brighter. 22 = make the keyboard light dimmer. 23 = stop the music. 24 = play a random song. 25 = read today's calendar or schedule. 26 = give the morning briefing. 27 = tell the Wi-Fi or internet status. 28 = tell the free disk space. 29 = tell which app is slowing the Mac or using the most memory. 30 = read the shopping list. 31 = read the reminders. 32 = tell how much time is left on the timer. 33 = open a new browser tab. 34 = close the browser tab. 35 = refresh the page. 36 = scroll down. 37 = scroll up. 38 = talk slower. 39 = talk faster. 40 = repeat what you just said."
        guard let answer = try? await Brain.shared.reply(system: system, history: [["role": "user", "content": text]]) else { return nil }
        guard let r = answer.range(of: "\\d+", options: .regularExpression), let n = Int(answer[r]) else { return nil }
        print("BRO: smart command picked \(n) for: \(text)")
        func keyCmd(_ name: String) -> VoiceCommand? {
            if let s = keyActions[name] { return VoiceCommand.keys(s) }
            return nil
        }
        switch n {
        case 1: return .brightnessChange(3)
        case 2: return .brightnessChange(-3)
        case 3: return .volumeChange(12)
        case 4: return .volumeChange(-12)
        case 5: return .volumeMute(true)
        case 6: return .volumeMute(false)
        case 7: return .darkMode(1)
        case 8: return .darkMode(0)
        case 9: return .media(16)
        case 10: return .media(17)
        case 11: return .media(18)
        case 12: return .weather(nil)
        case 13: return .time
        case 14: return .date
        case 15: return .battery
        case 16: return .news(nil)
        case 17: return .screenshot
        case 18: return .lockScreen
        case 19: return .kbLightOn
        case 20: return .kbLightSet(0)
        case 21: return .kbLightChange(15)
        case 22: return .kbLightChange(-15)
        case 23: return .stopMusic
        case 24: return .playRandomSong
        case 25: return .calendarToday
        case 26: return .briefing
        case 27: return .wifi
        case 28: return .disk
        case 29: return .topApps("both")
        case 30: return .listRead
        case 31: return .listAlerts("reminder")
        case 32: return .timeLeft
        case 33: return keyCmd("new tab")
        case 34: return keyCmd("close tab")
        case 35: return keyCmd("refresh")
        case 36: return keyCmd("scroll down")
        case 37: return keyCmd("scroll up")
        case 38: return .speechRate(-1)
        case 39: return .speechRate(1)
        case 40: return .repeatLast
        default: return nil
        }
    }

    // Asks the built-in brain to do a writing job (draft a message, summarize or fix the clipboard text).
    // The mic stays closed while it works. With copyResult the answer is also copied to the clipboard.
    func aiTextTask(_ request: String, copyResult: Bool) async {
        let system = "You are BRO, a helpful writing assistant. Do exactly what the user asks. Reply in English only, in plain text: no markdown, no quotation marks, and no opening phrase like \"Here is\". Keep it under 80 words."
        waitingForBrain = true
        var answer = ""
        do {
            answer = try await Brain.shared.reply(system: system, history: [["role": "user", "content": request]], onSlowLoad: { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self, self.isShown else { return }
                    self.stopListening()
                    self.speak("One moment, I am getting my brain ready.")
                }
            })
        } catch {
            print("BRO: the brain had a problem: \(error)")
        }
        waitingForBrain = false

        while let r = answer.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) { answer.removeSubrange(r) }
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            if isShown { speak("Sorry, say that again.") } else { model.state = .idle }
            return
        }
        if copyResult {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
        }
        print("BRO says: \(answer)")
        if isShown { speak(copyResult ? answer + " I copied it to your clipboard." : answer) } else { model.state = .idle }
    }

    // Speaks with the best free Mac voice (British Daniel for English, a Hindi voice for Devanagari text).
    func speak(_ text: String) {
        var clean = fixName(text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: ""))
        if quietSpeech {
            print("BRO (quiet): \(clean)")
            chainNotes.append(clean)
            return
        }
        if !chainNotes.isEmpty {                 // v54: say and write everything the chain did, in one go
            clean = (chainNotes + [clean]).joined(separator: " ")
            chainNotes = []
        }
        lastSpoken = clean
        chat.add("BRO", clean)
        let hindi = clean.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
        let u = AVSpeechUtterance(string: spokenForm(clean))
        u.voice = bestVoice(hindi: hindi)
        u.rate = currentSpeechRate()
        pendingSpeech += 1
        model.state = .speaking
        synth.speak(u)
    }

    func bestVoice(hindi: Bool) -> AVSpeechSynthesisVoice? {
        let prefix = hindi ? "hi" : "en"
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        if !hindi, let daniel = voices.first(where: { $0.name.contains(voiceName) }) { return daniel }
        return voices.first ?? AVSpeechSynthesisVoice(language: hindi ? "hi-IN" : "en-GB")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishedSpeaking()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishedSpeaking()
    }

    func stopListening() {
        mic.stop()
        model.micLevel = 0
    }

    var lastToggle = 0.0

    func toggle() {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastToggle < 0.8 { print("BRO: shortcut ignored (too fast)"); return }
        lastToggle = now
        print("BRO: shortcut pressed -> \(isShown ? "hide" : "show")")
        if isShown { hideBRO() } else { showBRO() }
    }

    func showBRO() {
        isShown = true
        if !synth.isSpeaking { pendingSpeech = 0 }
        model.state = .idle
        panel.orderFrontRegardless()
        playActivation()
        scheduleListening()
    }

    func hideBRO() {
        isShown = false
        model.state = .idle
        synth.stopSpeaking(at: .immediate)
        pendingSpeech = 0
        pttHeld = false
        restoreMusic()
        pttBuffer = []
        stopListening()
        restOrigin = panel.frame.origin
        guard let screen = NSScreen.main else { return }
        var f = panel.frame
        f.origin.y = screen.frame.minY - f.size.height
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.5
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(f, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self, !self.isShown else { return }
            self.panel.orderOut(nil)
        })
    }

    // The window starts fully below the bottom edge of the screen and glides up to its resting place.
    func playActivation() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        let origin = restOrigin ?? NSPoint(x: v.maxX - size.width - 40, y: v.minY + 40)
        let rest = NSRect(origin: origin, size: size)
        panel.setFrameOrigin(NSPoint(x: rest.origin.x, y: screen.frame.minY - size.height))
        model.triggerActivation()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 1.8
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(rest, display: true)
        }
    }
}

@main
struct BROApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
