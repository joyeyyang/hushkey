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
    /// A line about the keyboard's microphone tap when it could not be acted on.
    ///
    /// Its own slot rather than `dictation.error`: with no recogniser installed the
    /// model page is the whole app, and that page never draws the recorder's error
    /// line -- so a message about the tap has to live where every page can see it.
    @State private var requestNotice: String?
    @Environment(\.scenePhase) private var scenePhase

    private let titles = ["轉錄", "歷史", "關鍵字", "模型", "設定"]

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                if let requestNotice {
                    Text(requestNotice)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.seal)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            // The keyboard's microphone button, one of the three ways it arrives.
            if url.host == "record" { handleRecordRequest(channel: "url") }
        }
        .onChange(of: scenePhase) { _, phase in
            // The other two. A keyboard cannot be trusted to reach a running app:
            // iOS declines `extensionContext.open()` while the containing app is
            // resident, and a Darwin notification only reaches a listener. So the
            // request is written down by the keyboard as well, and this is where the
            // app picks it up -- becoming active is the moment the user is looking
            // at it, whichever way they got here.
            guard phase == .active else { return }
            handleRecordRequest(channel: "active")
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
        // The keyboard's microphone, third channel. Registered in BOTH modes: the
        // handler is the same request the URL carries, and in Mode 1 the URL often
        // is not delivered at all (iOS refuses the open while this app is resident)
        // -- so without this, a tap on a running app was a tap that did nothing.
        SharedStore.observeRecordRequest { handleRecordRequest(channel: "notification") }
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
            // A fresh keyboard request outranks last launch's spool. Starting the
            // recovery here would take the recogniser for the rest of the recovery
            // and the user's new dictation would sit behind it -- or be refused by
            // the core's single session. The request handler below consumes the
            // request before this deadline, so checking freshness here is enough to
            // keep a hot launch's microphone tap with the microphone.
            guard !SharedStore.hasFreshRecordRequest() else { return }
            dictation.recoverOrphan()
        }
        launchFlags()
        // A launch is an unprompted channel: honour a persisted keyboard request
        // only while it is recent, then let the same handler used by the URL and
        // Darwin notification switch to 轉錄 and start recording.
        handleRecordRequest(channel: "launch", freshOnly: true)
    }

    /// One entry point for the keyboard's microphone button.
    ///
    /// Three channels carry the same request, and which one arrives depends on what
    /// the app was doing when the button was tapped: `ovc://record` (the app was not
    /// running), the group's pending request picked up on activation (the app was
    /// running, and iOS may well have refused the open), or the Darwin notification
    /// (Mode 2, where the app is deliberately kept in the background). All three
    /// land here, and the request is consumed first so the second arrival cannot
    /// start a second dictation into a pipeline that already has one.
    /// - Parameter freshOnly: true for the channels that are NOT evidence of a new
    ///   tap -- a launch, coming back to the app. Those honour a request only while
    ///   it is recent, so a tap the app never got to does not fire days later.
    private func handleRecordRequest(channel: String, freshOnly: Bool = false) {
        let pending = SharedStore.hasPendingRecordRequest
        let actionable = pending && (!freshOnly || SharedStore.hasFreshRecordRequest())
        // The URL is a request in itself: if the group write went nowhere (Full
        // Access off, so no App Group) it is the only evidence the user tapped.
        guard actionable || channel == "url" else { return }
        SharedStore.consumeRecordRequest()
        Diagnostics.log.notice("record request via \(channel, privacy: .public)")
        requestNotice = nil
        // Whatever page the user was on, the one that answers a microphone tap is
        // 轉錄. Starting a recording while the screen says 設定 is what made a
        // working app look like one that had not noticed.
        tab = 0
        guard SharedStore.hasModels else {
            // This used to be a silent `return` on `modelsReady`, so the tap simply
            // vanished. The model page is already the whole app in this state, so
            // the line says what to do there.
            requestNotice = "還沒有可用的模型。先在這一頁裝好模型，再按鍵盤的麥克風。"
            return
        }
        dictation.start()
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
