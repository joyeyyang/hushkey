import Foundation

/// Which model the engine loads, and the record of why that ever changed.
///
/// The core already does the right thing inside one run: it opens the manifest's
/// 2B, and only if that cannot run does it retry with the largest smaller file it
/// finds, saying so on stderr. That is the whole repair for a one-off failure.
///
/// It is not enough on a phone. Memory pressure and the ~30 second background
/// window come back on every launch, so a device that genuinely cannot run the
/// 2B would pay the same price on every dictation: a 25 second wait, and a
/// cleanup pass that never lands. This remembers the outcome across launches and
/// hands the engine the smaller file directly.
///
/// Three rules are deliberate:
///
/// 1. **Down, never sideways.** A downgrade only ever names a file *smaller* than
///    the preferred one, because the only reason to be here is that the preferred
///    one asked for more time or memory than the device has.
/// 2. **Never silent.** Recording writes a log line naming both models and the
///    reason, and the model screen shows the state with a way back.
/// 3. **Preferred by default.** With no recorded downgrade nothing is set at all,
///    so the core's own preference order still decides -- there is no second,
///    drifting copy of that rule here.
enum LLMPolicy {
    /// What the manifest ships. The core's own default; used here only to know
    /// which end of the size ordering is "preferred".
    static let preferredName = "Qwen3.5-2B-Q4_K_M.gguf"

    struct Downgrade: Codable, Equatable {
        let from: String
        let to: String
        let reason: String
        let at: Date
    }

    private static let key = "llmDowngrade"

    // MARK: recorded state

    static var recorded: Downgrade? {
        guard let data = SharedStore.defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Downgrade.self, from: data)
    }

    /// The file the engine should be told to use, or nil to leave the core's
    /// preference order alone.
    static var activeName: String? {
        guard let downgrade = recorded else { return nil }
        // A recorded name whose file was deleted in the meantime would make the
        // engine answer "no model", so the record is only honoured while the file
        // is there.
        return installed.contains { $0.name == downgrade.to } ? downgrade.to : nil
    }

    // MARK: installed models

    struct Model: Equatable {
        let name: String
        let bytes: Int64
    }

    /// Every `.gguf` under `llm/`, biggest first.
    static var installed: [Model] {
        let dir = SharedStore.llmDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.lowercased().hasSuffix(".gguf") }
            .compactMap { name -> Model? in
                let path = dir.appendingPathComponent(name).path
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? NSNumber else { return nil }
                return Model(name: name, bytes: size.int64Value)
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// The file that should serve the next task: the preferred one when it is
    /// installed, otherwise the largest that is.
    static var preferredInstalled: Model? {
        installed.first { $0.name == preferredName } ?? installed.first
    }

    // MARK: decide

    /// The file the engine was actually told to use.
    ///
    /// Three sources, in the order the core reads them: a recorded downgrade
    /// (`apply` sets `OVC_LLM_MODEL`), a value the launch itself carried (a
    /// measurement run, a support override), and finally the manifest's default.
    /// This is the answer to "did the 2B fail, or was it never asked?" — a
    /// question the served model alone cannot answer, which is how a benchmark
    /// run that chose the 0.5B on purpose was recorded as "2B failed" and left
    /// this device permanently on the small model.
    static var requestedName: String {
        if let active = activeName { return active }
        if let raw = ProcessInfo.processInfo.environment["OVC_LLM_MODEL"],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return (raw as NSString).lastPathComponent
        }
        return preferredName
    }

    /// Hands the engine a downgraded model, if one was recorded.
    ///
    /// Called once, from `Core.initialize`. It runs *after* `Core_Initialize`
    /// (that call only points the engine at the model tree) and before the first
    /// LLM task, which is when `OVC_LLM_MODEL` is actually read -- so the
    /// ordering that matters is "before the first dictation", not "before init".
    static func apply() {
        guard let name = activeName else { return }
        setenv("OVC_LLM_MODEL", name, 1)
        let reason = recorded?.reason ?? ""
        Diagnostics.log.error(
            "llm model: using \(name, privacy: .public) instead of \(preferredName, privacy: .public) — \(reason, privacy: .public)"
        )
    }

    /// Remembers that `served` answered when the preferred model was asked for.
    ///
    /// `served` comes from the core (`LLM_LastModelName`), so it is a fact rather
    /// than an inference -- but only about *what ran*. Whether it was a fallback
    /// depends on what was *requested*, and that is a second fact this function
    /// has to check for itself: a run that asked for the 0.5B on purpose (a
    /// measurement, an override) answers with the 0.5B and is not a downgrade.
    /// Treating those as one recorded a permanent downgrade on a device whose 2B
    /// had never failed, and the reason line then said "2B 無法執行" about
    /// something that was never tried.
    @discardableResult
    static func recordIfDowngraded(served: String, reason: String) -> Bool {
        guard !served.isEmpty, served != preferredName else { return false }
        // Not asked for the big one: nothing failed, so nothing to record.
        guard requestedName == preferredName else {
            Diagnostics.log.notice(
                "llm model: served \(served, privacy: .public) because it was requested, not as a fallback"
            )
            return false
        }
        guard let preferred = preferredInstalled, preferred.name == preferredName else { return false }
        guard let candidate = installed.first(where: { $0.name == served }),
              candidate.bytes < preferred.bytes else { return false }
        // Already recorded and the same file: nothing to add.
        if recorded?.to == served { return false }
        return record(to: candidate.name, reason: reason)
    }

    /// Records a downgrade to the largest installed model smaller than the one
    /// that just failed. Returns false when there is nothing to downgrade to.
    @discardableResult
    static func recordDowngrade(reason: String) -> Bool {
        // Step down from the file that is actually in force, not from the
        // preferred one. With three models installed (2B / 1.5B / 0.5B), always
        // comparing against the 2B means the second failure picks the 1.5B again
        // -- the same file that just overran -- and the log then claims nothing
        // smaller is installed while the 0.5B sits right there.
        let floor = activeName ?? preferredName
        guard let current = installed.first(where: { $0.name == floor }) ?? preferredInstalled else {
            Diagnostics.log.error("llm model: no installed model to step down from")
            return false
        }
        guard let smaller = installed.first(where: { $0.name != current.name && $0.bytes < current.bytes }) else {
            Diagnostics.log.error(
                "llm model: \(current.name, privacy: .public) could not keep up, but no smaller model is installed — staying on it"
            )
            return false
        }
        return record(to: smaller.name, reason: reason)
    }

    private static func record(to name: String, reason: String) -> Bool {
        let downgrade = Downgrade(from: preferredName, to: name, reason: reason, at: Date())
        if let data = try? JSONEncoder().encode(downgrade) {
            SharedStore.defaults?.set(data, forKey: key)
        }
        Diagnostics.log.error(
            "llm model downgrade recorded: \(preferredName, privacy: .public) → \(name, privacy: .public) — \(reason, privacy: .public) (applies from the next launch)"
        )
        return true
    }

    /// Forgets the downgrade so the preferred model is tried again.
    ///
    /// Needed because a downgrade recorded under memory pressure, or on a phone
    /// that was busy, should not be permanent. The model screen offers it.
    ///
    /// It also forgets that the big model ever succeeded, because that fact was
    /// evidence about *that* attempt and a user pressing "try the big one again" is
    /// asking for a clean slate, not for a head start.
    static func clear() {
        SharedStore.defaults?.removeObject(forKey: key)
        SharedStore.defaults?.removeObject(forKey: successKey)
        unsetenv("OVC_LLM_MODEL")
        Diagnostics.log.error("llm model downgrade cleared; \(preferredName, privacy: .public) will be tried again")
    }

    // MARK: proof

    private static let successKey = "llmPreferredSucceeded"

    /// Whether the model that is supposed to answer has ever finished a pass here.
    ///
    /// This is the difference between "too slow for this phone" and "too slow on
    /// its very first run". The first cleanup after an install pays
    /// `ggml_metal_library_compile_all` — measured at 17.8 seconds on an A17 Pro —
    /// on top of ~3 seconds of generation, which is close enough to the 25-second
    /// background deadline that a slower phone genuinely can trip it. Recording a
    /// downgrade there would make a one-time compile into a permanent model change,
    /// which is the exact failure this file's history is about.
    static var preferredHasSucceeded: Bool {
        SharedStore.defaults?.bool(forKey: successKey) ?? false
    }

    static func notePreferredServed() {
        guard !preferredHasSucceeded else { return }
        SharedStore.defaults?.set(true, forKey: successKey)
        Diagnostics.log.notice("llm model: \(preferredName, privacy: .public) finished a pass on this device")
    }
}
