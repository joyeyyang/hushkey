import SwiftUI
import UIKit

/// 轉錄: the one page that is about the sentence being said right now.
///
/// Shaped after the Mac's floating surface rather than after a chat app: the words
/// arrive in one block, the status is one word, and the controls are the two the
/// user actually needs (stop, or pause and keep going). The cleanup switch and the
/// mode switch sit below because they change *how* the next sentence is produced,
/// not what is happening now.
struct RecorderTab: View {
    @ObservedObject private var dictation = DictationController.shared
    @State private var refine = SharedStore.refineEnabled
    @State private var mode = SharedStore.mode
    @State private var modeNotice: String?
    @State private var copied = false
    @State private var importing = false
    /// The transcript's selected range, reported by the text view. The 修改提示詞
    /// panel's 「選取範圍」 region is this, not a re-derivation of it.
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        VStack(spacing: 14) {
            transcriptCard

            if let error = dictation.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.seal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if dictation.phase == .done {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("已送到鍵盤。點左上「◀ 上一個 App」回去，字會在游標出現。")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Palette.ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = dictation.display
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "已複製" : "複製",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(QuietButton())
                .disabled(dictation.display.isEmpty)

                Button {
                    dictation.clear()
                } label: {
                    Label("清除", systemImage: "xmark")
                }
                .buttonStyle(QuietButton())
                .disabled(dictation.display.isEmpty && dictation.phase == .idle)
            }

            // The second pass, and only the second: the sentence is done, so
            // there is something to revise. 整理 above is the cleanup every
            // sentence gets; this one runs only when the user asks and only on
            // the region they name.
            if !dictation.display.isEmpty && !dictation.isBusy {
                PromptEditPanel(
                    dictation: dictation,
                    selection: selection,
                    text: dictation.display
                )
            }

            // The same switch the desktop has, and the same default: the cleanup
            // pass is what makes a transcript readable to someone else, so it is on
            // until a user says otherwise.
            Toggle(isOn: Binding(
                get: { refine },
                set: { refine = $0; SharedStore.refineEnabled = $0 }
            )) {
                HStack(spacing: 6) {
                    Text("AI 整理").font(.system(size: 13))
                    Text("標點、去贅字、保留原意")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
            }
            .tint(Palette.seal)
            .disabled(dictation.isBusy)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Mode 1 / Mode 2. Flat, two words, current one underlined -- the same
            // shape as the rest of this screen rather than a segmented control.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    modeButton("跳回 App", .toApp)
                    modeButton("留在原 App（小窗）", .pip)
                }
                if let modeNotice {
                    Text(modeNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.seal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controls

            Text("在 iPhone 上要這樣用：設定 › 一般 › 鍵盤 › 鍵盤 › 加入新的鍵盤 › Hushkey，之後在任何輸入框切到它，按麥克風。停下來 1 秒會自動停止。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: AudioImport.allowed,
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { dictation.transcribeFile(url) }
        }
    }

    private var transcriptCard: some View {
        ScrollView {
            // A UITextView rather than `Text`: 「選取範圍」 needs the app to read
            // WHICH characters the user selected, and `.textSelection(.enabled)`
            // draws a selection the app cannot see.
            SelectableTranscript(
                text: dictation.display,
                placeholder: emptyHint,
                selection: $selection
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxHeight: .infinity)
    }

    private var emptyHint: String {
        switch dictation.phase {
        case .recording: return dictation.isPaused ? "已暫停。按繼續接著說。" : "請開始說話。"
        case .transcribing: return "辨識中…"
        default: return "按下面的麥克風，說一句話。\n文字會出現在這裡，也會送到鍵盤。"
        }
    }

    /// The microphone, and — while recording — 暫停 / 繼續 beside it.
    ///
    /// Pause is the Mac's pause: the recording is not finished, the sentence keeps
    /// accumulating, and nothing is decoded until the user stops. It exists because
    /// a phone dictation is interrupted constantly (a notification, someone else
    /// talking, a lift ride) and the alternative is either publishing half a
    /// sentence or losing the first half.
    private var controls: some View {
        HStack(spacing: 22) {
            if dictation.isRecording {
                Button {
                    if dictation.isPaused { dictation.resume() } else { dictation.pause() }
                } label: {
                    Image(systemName: dictation.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 52, height: 52)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Button {
                if dictation.isRecording {
                    dictation.stop()
                } else {
                    dictation.start()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(dictation.isRecording ? Palette.seal : Color.white.opacity(0.10))
                        .frame(width: 86, height: 86)
                    if dictation.isBusy && !dictation.isRecording {
                        ProgressView().tint(Palette.ink)
                    } else {
                        Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(dictation.isRecording ? Color.white : Palette.ink)
                    }
                }
            }
            .disabled(dictation.isBusy && !dictation.isRecording)

            Button {
                importing = true
            } label: {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(dictation.isBusy)
        }
    }

    private func modeButton(_ title: String, _ target: SharedStore.Mode) -> some View {
        Button {
            mode = target
            SharedStore.mode = target
            if target == .pip {
                startPiP()
            } else {
                PiPController.shared.stop()
                modeNotice = nil
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: mode == target ? .semibold : .regular))
                .foregroundStyle(mode == target ? Palette.ink : Palette.dim)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(mode == target ? Palette.ink : .clear)
                        .frame(height: 1)
                        .offset(y: 3)
                }
        }
        .buttonStyle(.plain)
    }

    /// Starts the PiP window, and says so in the UI when the device will not.
    ///
    /// Silence here is the failure mode worth preventing: a user who picks "stay in
    /// the other app" and gets a microphone button that does nothing has no way to
    /// tell whether they mis-tapped or the device refused.
    private func startPiP() {
        Diagnostics.log.notice("pip: start requested")
        // PiP anchors to a view that is on screen, and the key window is exactly
        // that whenever the user can tap the switch.
        let host = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first { $0.isKeyWindow }
        guard let anchor = host else {
            Diagnostics.log.error("pip: no key window yet; Mode 2 deferred")
            modeNotice = "小窗還沒準備好，稍後再試一次。"
            return
        }
        guard PiPController.isSupported else {
            // The simulator is the usual reason, and it is not a bug to work
            // around: no call-style PiP there, so Mode 2 cannot be demonstrated
            // off-device. Say it in the log rather than only on screen.
            Diagnostics.log.error("pip: unsupported on this device; falling back to Mode 1")
            modeNotice = "這台裝置不支援小窗（PiP），已改回跳回 App。"
            mode = .toApp
            SharedStore.mode = .toApp
            return
        }
        PiPController.shared.start(in: anchor)
        modeNotice = "小窗會在本 App 切到背景後出現。"
    }
}
