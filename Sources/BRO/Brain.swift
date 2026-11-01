// Brain.swift - BRO's built-in offline brain (MLX Swift). Separate file, easy to merge.
// Usage from BRO:  let text = try await Brain.shared.reply(system: sys, history: msgs)
// history = [["role":"user"|"assistant", "content":"..."]], the LAST user message is the question.
// At BRO start (once, in a background Task):  await Brain.shared.prepareIfNeeded(onDownloadStart: { ...speak "one moment"... })

import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

enum BrainError: Error {
    case noUserMessage
    case emptyReply
}

actor Brain {
    static let shared = Brain()

    // ---- SETTINGS (change here later to switch the brain) ----
    static let modelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    /// 10 minutes normally, 3 minutes when the Mac is in Low Power Mode (saves memory and battery)
    var idleMinutes: Int { ProcessInfo.processInfo.isLowPowerModeEnabled ? 3 : 10 }
    let maxTokens = 160
    let temperature: Float = 0.5
    // ----------------------------------------------------------

    private static let readyKey = "broBrainDownloaded"

    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var lastUse = Date()
    private var idleTask: Task<Void, Never>?

    /// Call once when BRO starts (inside a background Task). Only the FIRST time it downloads the model,
    /// so the first real question is fast. Later launches do nothing. onDownloadStart fires if it takes > 2 s
    /// (BRO can say "one moment"). If it fails (no internet), nothing breaks: the model loads at the first question.
    func prepareIfNeeded(onDownloadStart: (@Sendable () -> Void)? = nil) async {
        if UserDefaults.standard.bool(forKey: Brain.readyKey) { return }
        do {
            _ = try await ensureLoaded(onSlowLoad: onDownloadStart)
            UserDefaults.standard.set(true, forKey: Brain.readyKey)
            lastUse = Date()
            startIdleWatcher()   // frees memory after idleMinutes
        } catch {
            // ignore: will try again at the first question
        }
    }

    /// onSlowLoad is called if loading takes more than 2 seconds (BRO can say "one moment").
    /// On an empty reply or an error it reloads the model and tries once more before giving up.
    func reply(system: String,
               history: [[String: String]],
               onSlowLoad: (@Sendable () -> Void)? = nil) async throws -> String {
        lastUse = Date()
        startIdleWatcher()

        guard let idx = history.lastIndex(where: { $0["role"] == "user" }),
              let userText = history[idx]["content"] else {
            throw BrainError.noUserMessage
        }

        let earlier = history[..<idx].suffix(8)
        let transcript = earlier.compactMap { m -> String? in
            guard let role = m["role"], let content = m["content"], role != "system" else { return nil }
            return (role == "user" ? "User: " : "BRO: ") + content
        }.joined(separator: "\n")

        var instructions = system
        if !transcript.isEmpty {
            instructions += "\n\nConversation so far:\n" + transcript
        }

        var lastError: Error = BrainError.emptyReply
        for attempt in 0..<2 {
            do {
                let c = try await ensureLoaded(onSlowLoad: onSlowLoad)
                let session = ChatSession(
                    c,
                    instructions: instructions,
                    generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature)
                )
                let text = try await session.respond(to: userText)
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    lastUse = Date()
                    return clean
                }
                lastError = BrainError.emptyReply
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            if attempt == 0 {
                unload()               // reload fresh and try once more
                startIdleWatcher()
            }
        }
        throw lastError
    }

    /// Frees the model from memory right now.
    func unload() {
        container = nil
        loading = nil
        idleTask?.cancel()
        idleTask = nil
    }

    private func ensureLoaded(onSlowLoad: (@Sendable () -> Void)?) async throws -> ModelContainer {
        if let c = container { return c }

        var notice: Task<Void, Never>?
        if let onSlowLoad {
            notice = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled { onSlowLoad() }
            }
        }
        defer { notice?.cancel() }

        let task: Task<ModelContainer, Error>
        if let t = loading {
            task = t
        } else {
            let id = Brain.modelID
            task = Task {
                try await #huggingFaceLoadModelContainer(
                    configuration: ModelConfiguration(id: id)
                )
            }
            loading = task
        }

        do {
            let c = try await task.value
            container = c
            loading = nil
            return c
        } catch {
            loading = nil
            throw error
        }
    }

    private func startIdleWatcher() {
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                if await self.shouldUnload() {
                    await self.unload()
                    return
                }
            }
        }
    }

    private func shouldUnload() -> Bool {
        return container != nil && Date().timeIntervalSince(lastUse) > Double(idleMinutes * 60)
    }
}
