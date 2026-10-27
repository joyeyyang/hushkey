import SwiftUI

/// The app's five pages, the same five the Mac has.
///
/// 轉錄 / 歷史 / 關鍵字 / 模型 / 設定. The order is the Mac's order, and the pages
/// hold the same things: dictation and its switches, every finished sentence,
/// the proper-noun list, what models are installed, and the settings that change
/// how a sentence is produced.
///
/// A phone adds one constraint the Mac does not have, and it is why this screen is
/// not the product: the keyboard is. Everything here exists to make the keyboard's
/// one button behave, plus the things a keyboard extension cannot do (open a
/// microphone, keep history, write a file).
struct RootView: View {
    @ObservedObject private var dictation = DictationController.shared
    @State private var modelsReady = SharedStore.hasModels
    @State private var tab = 0
    /// `prepare` runs once per launch, whoever asks for it first.
    ///
    /// It is attached to two views (the screen and the model page), because either
    /// can be the first thing that appears. Without this, a launch with no models
    /// installed ran it twice, and the second pass rescheduled the `-OVC_CLEAR`
    /// probe's timers.
    @State private var prepared = false

    private let titles = ["轉錄", "歷史", "關鍵字", "模型", "設定"]

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                if !modelsReady {
                    // Nothing below this line works without a recogniser, so the
                    // model page is the whole app until one is installed. Tabs
                    // that lead to pages which cannot run are worse than no tabs.
                    ModelsTab(ready: $modelsReady)
                        .onAppear(perform: prepare)
                } else {
                    TabStrip(titles: titles, selected: tab) { tab = $0 }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    content
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: prepare)
        .onOpenURL { url in
            // The keyboard's microphone button. Cold launch and re-entry both land
            // here, and both should start recording immediately.
            if url.host == "record", modelsReady { dictation.start() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(modelsReady ? titles[tab] : "模型")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            // The status word the Mac shows in its window header. It is the only
            // place the phase is visible from a page that is not 轉錄, which is
            // what stops "did it hear me?" from requiring a tab switch.
            Text(statusWord)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case 1: HistoryTab()
        case 2: KeywordsTab()
        case 3: ModelsTab(ready: $modelsReady)
        case 4: SettingsTab()
        default: RecorderTab()
        }
    }

    private var statusWord: String {
        switch dictation.phase {
        case .recording: return dictation.isPaused ? "已暫停" : "錄音中"
        case .transcribing: return "辨識中"
        case .refining: return "整理中"
        case .done: return "完成"
        case .failed: return "錯誤"
        case .idle: return "待機"
        }
    }

    private var statusColor: Color {
        switch dictation.phase {
        case .recording, .failed: return Palette.seal
        case .done: return Palette.ink
        default: return Palette.dim
        }
    }

    /// Everything a launch has to settle before a page can be trusted.
    ///
    /// Also reachable twice: `onAppear` fires again when the model sheet closes,
    /// and re-running the recovery would deliver last launch's sentence twice.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        // A launch is proof that no PiP window from a previous run survived: the
        // delegate that clears this flag never runs in a process the system kills,
        // and a stale `true` is what turns the keyboard's microphone into a button
        // that records nothing.
        SharedStore.pipLive = false
        // Before any check: the model screen's whole point is to be a place the
        // user can put something, so the folders exist first and the status is
        // recomputed from what is actually on disk.
        SharedStore.prepareModelDirs()
        modelsReady = SharedStore.hasModels
        guard modelsReady else { return }
        // Mode 2's trigger: the keyboard asks over the group, and nothing switches
        // apps.
        SharedStore.observeRecordRequest { [dictation] in
            guard SharedStore.mode == .pip else { return }
            dictation.start()
        }
        // A phase left behind by a process the system killed reads as a dictation
        // still in progress, and the keyboard then shows a stop button for
        // something that will never finish.
        let left = SharedStore.current().phase
        if left == .recording || left == .transcribing || left == .refining {
            SharedStore.setPhase(.idle, detail: "上次的聽寫沒有完成")
        }
        dictation.prewarm()
        // Audio from a run the system killed before it could publish. Waiting one
        // and a half seconds is deliberate: a cold launch from the keyboard's
        // microphone arrives through `onOpenURL` right after this, and recovering
        // first would take the microphone for twenty seconds while the user talks
        // into a dictation that never started.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [dictation] in
            guard dictation.phase == .idle else { return }
            dictation.recoverOrphan()
        }
        launchFlags()
    }

    /// Probes a script cannot otherwise reach: a simulator cannot be tapped, and a
    /// device cannot be typed into from the command line.
    private func launchFlags() {
        let arguments = ProcessInfo.processInfo.arguments
        // `-OVC_TAB <0-4>`: open on a given page. A screenshot check that cannot
        // reach 歷史 or 設定 is a check of one page out of five, and the other four
        // are exactly where a broken binding or an empty-state crash would live.
        if let index = arguments.firstIndex(of: "-OVC_TAB"),
           arguments.index(after: index) < arguments.endIndex,
           let value = Int(arguments[arguments.index(after: index)]),
           titles.indices.contains(value) {
            tab = value
        }
        if arguments.contains("-OVC_PIP_PROBE") {
            SharedStore.mode = .pip
            Diagnostics.log.notice("pip probe: requested at launch")
        }
        guard arguments.contains("-OVC_CLEAR") else { return }
        // Two seconds: late enough that a recovery has started by then, early
        // enough to land inside its decode rather than after the sentence was
        // already published. Both outcomes are worth exercising; the log says
        // which one happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [dictation] in
            Diagnostics.log.notice("clear requested at launch")
            dictation.clear()
            // The user's next move after 清除 is another dictation in the same
            // process. A cancelled recovery that left the recogniser session open
            // only shows up here.
            if let path = Diagnostics.audioAfterClear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    Diagnostics.log.notice("dictation requested after clear")
                    dictation.runInjected(url: URL(fileURLWithPath: path))
                }
            }
        }
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07),
                        in: RoundedRectangle(cornerRadius: 10))
    }
}
