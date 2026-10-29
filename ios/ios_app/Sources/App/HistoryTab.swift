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
