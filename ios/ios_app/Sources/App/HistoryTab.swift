import SwiftUI
import UIKit

/// 歷史: every finished sentence.
///
/// The Mac's tab, for a reason that is stronger on a phone. Dictation lands in
/// whatever field had focus; on a Mac that field is usually still on screen, and on
/// a phone the app may have been switched away from, the message may have been
/// sent, or the keyboard may have been dismissed before the text was read. Without
/// this list the sentence is simply gone.
struct HistoryTab: View {
    @State private var entries: [HistoryEntry] = History.all()
    @State private var query = ""
    @State private var share: URL?
    @State private var confirmingClear = false
    @State private var copied: UUID?
    /// 會議紀錄: one value for the three states, because they are one sheet.
    /// Two sheets (busy, then result) is a presentation racing a dismissal --
    /// SwiftUI drops the second sheet often enough that the summary silently never
    /// appears.
    @State private var minutes: MinutesState?

    private var shown: [HistoryEntry] { History.matching(query) }

    var body: some View {
        VStack(spacing: 12) {
            searchBar

            if shown.isEmpty {
                empty
            } else {
                list
            }

            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .onAppear { entries = History.all() }
        .sheet(item: Binding(
            get: { share.map(ShareItem.init) },
            set: { if $0 == nil { share = nil } }
        )) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: Binding(
            get: { minutes != nil },
            set: { if !$0 { minutes = nil } }
        )) {
            if let minutes {
                MeetingMinutesSheet(
                    state: minutes,
                    onShare: { share = Export.minutes($0) },
                    onClose: { self.minutes = nil }
                )
            }
        }
    }

    /// The three states of the 會議紀錄 sheet.
    enum MinutesState: Equatable {
        case busy(Int)
        case done(String)
        case failed(String)
    }

    /// Runs the summary pass over the list on screen.
    ///
    /// The list, not the whole history: a search for one project is the usual way a
    /// meeting's sentences are found here, and `History.matching` is already the
    /// answer to "which sentences". The sheet says out loud that it takes a while —
    /// three section calls, each running a 2B model on this phone.
    private func minutesOfShown() {
        let entries = History.matching(query)
        guard !entries.isEmpty else { return }
        minutes = .busy(entries.count)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MeetingMinutes.minutes(of: entries) }
            DispatchQueue.main.async {
                switch result {
                case .success(let text): minutes = .done(text)
                case .failure(let error): minutes = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// `sheet(item:)` needs an Identifiable, and a bare URL is not one.
    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Palette.dim)
            TextField("搜尋內容…", text: $query)
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text(query.isEmpty ? "還沒有紀錄" : "找不到符合的紀錄")
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(Palette.ink)
            Text(query.isEmpty
                 ? "每次聽寫完成的內容都會自動存在這裡，可以搜尋、複製。"
                 : "換個關鍵字試試；搜尋比對的是整句內容。")
                .font(.system(size: 12))
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(shown) { entry in
                    row(entry)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.day)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.dim)
                }
                Spacer(minLength: 0)
                if copied == entry.id {
                    Text("已複製")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.ink)
                }
            }
            Text(entry.text)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Not a line limit: the whole sentence is the point, and a
                // truncated history is a history you cannot trust.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 14) {
                Button("複製") {
                    UIPasteboard.general.string = entry.text
                    copied = entry.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        if copied == entry.id { copied = nil }
                    }
                }
                Button("分享") {
                    share = Export.file(.markdown, text: entry.text)
                }
                Button("刪除") {
                    History.delete(entry.id)
                    entries = History.all()
                }
                Spacer(minLength: 0)
                if entry.seconds > 0 {
                    // Why this number is here: "the cleanup got slower" is the
                    // complaint the model screen cannot answer, and a duration per
                    // sentence is what makes it measurable without a cable.
                    Text(String(format: "%.1f 秒", entry.seconds))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                }
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundStyle(Palette.dim)
        }
        .padding(12)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("共 \(shown.count) 筆" + (query.isEmpty ? "" : "（全部 \(entries.count) 筆）"))
                .font(.system(size: 11))
                .foregroundStyle(Palette.dim)

            // Four formats, two per row: four across does not fit a phone, and a
            // menu would hide the one the user came for behind a tap.
            HStack(spacing: 10) {
                Button("匯出 Markdown") { share = Export.file(.markdown, entries: shown) }
                    .buttonStyle(QuietButton())
                    .disabled(shown.isEmpty)
                Button("匯出 SRT") { share = Export.file(.srt, entries: shown) }
                    .buttonStyle(QuietButton())
                    .disabled(shown.isEmpty)
            }
            HStack(spacing: 10) {
                Button("匯出純文字") { share = Export.file(.txt, entries: shown) }
                    .buttonStyle(QuietButton())
                    .disabled(shown.isEmpty)
                Button("匯出 JSON") { share = Export.file(.json, entries: shown) }
                    .buttonStyle(QuietButton())
                    .disabled(shown.isEmpty)
            }

            Button("整理成會議紀錄") { minutesOfShown() }
                .buttonStyle(QuietButton())
                .disabled(shown.isEmpty)

            Button("全部清空") { confirmingClear = true }
                .buttonStyle(QuietButton())
                .disabled(entries.isEmpty)
        }
        .alert("要清空全部 \(entries.count) 筆歷史紀錄嗎？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) {
                History.clear()
                entries = []
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("這個動作無法復原。逐字稿已經貼到別的 App 的話，那個副本不受影響。")
        }
    }
}

/// 會議紀錄: the wait, the answer, and the two things to do with it.
///
/// The wait is a screen rather than a spinner on the button, and it says what it
/// is doing and that it cannot be stopped — the pass runs three sections through
/// the model, and a 取消 button would either lie about cancelling or leave the
/// model generating into nothing.
///
/// **No 我：/對方： here.** The Mac's meeting mode captures system audio as well as
/// the microphone, which is what makes the two speakers tellable apart. iOS cannot
/// read another app's audio without a ReplayKit broadcast extension and this build
/// has none, so the sentences go in without labels rather than with invented ones.
struct MeetingMinutesSheet: View {
    let state: HistoryTab.MinutesState
    let onShare: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch state {
                case .busy(let count):
                    HStack(spacing: 10) {
                        ProgressView().tint(Palette.seal)
                        Text("整理中…")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.ink)
                    }
                    Text("把這 \(count) 句當成一份會議逐字稿，跑三次模型：摘要、決議、待辦。手機上一次要 30 秒以上，跑起來就不能中途取消。請讓 App 留在前景。")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let message):
                    Text("沒有生出會議紀錄")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.seal)
                        .fixedSize(horizontal: false, vertical: true)
                case .done(let text):
                    Text("會議紀錄")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(Palette.ink)
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("只用了逐字稿裡的事實。決議與待辦是模型的判讀，貼出去之前先看一眼。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(Palette.dim.opacity(0.25))
                HStack(spacing: 10) {
                    if case .done(let text) = state {
                        Button("複製") { UIPasteboard.general.string = text }
                            .buttonStyle(QuietButton())
                        Button("分享 .md") { onShare(text) }
                            .buttonStyle(QuietButton())
                    }
                    Spacer(minLength: 0)
                    Button("關閉", action: onClose)
                        .buttonStyle(QuietButton())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Palette.paper.ignoresSafeArea())
        .interactiveDismissDisabled(isBusy)
    }

    private var isBusy: Bool {
        if case .busy = state { return true }
        return false
    }
}
