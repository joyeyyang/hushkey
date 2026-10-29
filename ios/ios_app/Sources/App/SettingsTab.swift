import AVFoundation
import SwiftUI
import UIKit

/// 設定: the choices that change how a sentence is produced.
///
/// The Mac's card group, minus the parts iOS does not have. What is kept is kept
/// faithfully — the four translation modes mean exactly what they mean on the
/// desktop, and the refine-stage ladder is the same one — because a setting that
/// behaves differently on the two platforms is worse than a missing one.
struct SettingsTab: View {
    /// The paper the app is drawn with. Observed rather than read once, so the row
    /// the tick is on follows the choice immediately.
    @ObservedObject private var themes = ThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var translate = Preferences.translate
    @State private var stages = Preferences.refineStages
    @State private var tone = SharedStore.refineTone
    @State private var refine = SharedStore.refineEnabled
    @State private var confirmInsert = SharedStore.confirmBeforeInsert
    @State private var micGranted: Bool?
    @State private var copiedPath = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                translateCard
                cleanupCard
                insertCard
                appearanceCard
                permissionsCard
                aboutCard
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .onAppear {
            translate = Preferences.translate
            stages = Preferences.refineStages
            tone = SharedStore.refineTone
            refine = SharedStore.refineEnabled
            confirmInsert = SharedStore.confirmBeforeInsert
        }
    }

    // MARK: translate

    private var translateCard: some View {
        Card("翻譯", caption: "整理之後才翻譯。同一個提示詞同時做兩件事，會生出翻一半的句子。") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(TranslateMode.allCases, id: \.self) { mode in
                    Button {
                        translate = mode
                        Preferences.translate = mode
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: translate == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 14))
                                .foregroundStyle(translate == mode ? Palette.ink : Palette.dim)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.ink)
                                Text(mode.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.dim)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: cleanup

    private var cleanupCard: some View {
        Card("AI 整理",
             caption: "段數是模型要跑幾遍：0 讓引擎依長度自己決定，1 直接濃縮，2 先理解再濃縮。語氣只影響改寫出來的樣子，段數只影響跑幾遍；選了輕鬆或正式就是單段。") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { refine },
                    set: { refine = $0; SharedStore.refineEnabled = $0 }
                )) {
                    Text("開啟 AI 整理").font(.system(size: 14)).foregroundStyle(Palette.ink)
                }
                .tint(Palette.seal)

                HStack(spacing: 16) {
                    ForEach([0, 1, 2], id: \.self) { value in
                        Button {
                            stages = value
                            Preferences.refineStages = value
                        } label: {
                            Text(value == 0 ? "自動" : "\(value) 段")
                                .font(.system(size: 12, weight: stages == value ? .semibold : .regular))
                                .foregroundStyle(stages == value ? Palette.ink : Palette.dim)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(stages == value ? Palette.ink : .clear)
                                        .frame(height: 1)
                                        .offset(y: 3)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)

                // The register. Its own row rather than a second ladder next to
                // 段數: the two are independent choices, and putting them side by
                // side reads as one six-way setting.
                Divider().overlay(Palette.dim.opacity(0.25))

                HStack(spacing: 16) {
                    ForEach(ToneOption.allCases, id: \.self) { option in
                        Button {
                            tone = option.rawValue
                            SharedStore.refineTone = option.rawValue
                        } label: {
                            Text(option.title)
                                .font(.system(size: 12, weight: tone == option.rawValue ? .semibold : .regular))
                                .foregroundStyle(tone == option.rawValue ? Palette.ink : Palette.dim)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(tone == option.rawValue ? Palette.ink : .clear)
                                        .frame(height: 1)
                                        .offset(y: 3)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)

                if let current = ToneOption(rawValue: tone) {
                    Text(current.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
            }
        }
    }

    // MARK: insert

    /// 貼上前確認, the phone's half of it.
    ///
    /// On the Mac the result waits in an editable HUD with an Enter key in front of
    /// it. A keyboard extension has no such key and no room for a second window, so
    /// the sentence waits in the keyboard's own panel and 插入 is the Enter. The
    /// value lives in the App Group because the keyboard is the side that reads it.
    private var insertCard: some View {
        Card("插入",
             caption: "開啟後，聽寫完的字會先留在鍵盤上；按「插入」才進到游標處，「重說一次」重講一遍，「丟棄」就什麼都不插入。和電腦版的「貼上前確認」同一個意思，只是手機上沒有 Enter，確認鍵就是「插入」。") {
            Toggle(isOn: Binding(
                get: { confirmInsert },
                set: { confirmInsert = $0; SharedStore.confirmBeforeInsert = $0 }
            )) {
                Text("貼上前確認").font(.system(size: 14)).foregroundStyle(Palette.ink)
            }
            .tint(Palette.seal)
        }
    }

    // MARK: appearance

    /// The Mac's 外觀 row, on the phone.
    ///
    /// The same six choices in the same order — 跟隨系統 first, then the five
    /// papers — because "the same on both platforms" was the point of the
    /// alignment work, and a phone that offered four slightly different papers
    /// would be the same failure with more steps. The colours themselves live in
    /// `PaperThemes`, copied hex for hex from the Mac's `Theme.swift`.
    private var appearanceCard: some View {
        Card("外觀",
             caption: "紙與墨。跟在電腦版選的是同一組，逐色相同。跟隨系統會看手機的淺色／深色設定。") {
            VStack(alignment: .leading, spacing: 0) {
                themeRow(
                    id: "system",
                    name: "跟隨系統",
                    theme: colorScheme == .dark ? PaperThemes.night : PaperThemes.paper,
                    detail: "手機在深色模式時用「夜墨」。"
                )
                ForEach(PaperThemes.all) { paper in
                    Divider().overlay(Palette.dim.opacity(0.2))
                    themeRow(id: paper.id, name: paper.name, theme: paper, detail: nil)
                }
            }
        }
    }

    private func themeRow(
        id: String, name: String, theme: PaperTheme, detail: String?
    ) -> some View {
        Button {
            themes.select(id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                swatch(theme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.dim)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: themes.id == id ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(themes.id == id ? Palette.ink : Palette.dim)
                    .padding(.top, 1)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Paper, seal, ink — the three colours that say what a theme is, in the order
    /// you would paint them.
    private func swatch(_ theme: PaperTheme) -> some View {
        HStack(spacing: 0) {
            theme.paper
            theme.seal
            theme.ink
        }
        .frame(width: 36, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Palette.dim.opacity(0.35), lineWidth: 0.5)
        )
        .padding(.top, 1)
    }

    // MARK: permissions

    /// What has to be true for the keyboard to work, said in the order the user
    /// hits them.
    ///
    /// A keyboard extension cannot check "允許完全取用" — the App Group is simply
    /// absent when it is off — so the app can only say where the switch is. It can
    /// check the microphone, and does, because a denied microphone is the failure
    /// that looks like the app being broken rather than like a permission.
    private var permissionsCard: some View {
        Card("權限") {
            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    title: "麥克風",
                    detail: microphoneDetail,
                    ok: micGranted == true
                )
                permissionRow(
                    title: "鍵盤與完全取用",
                    detail: "設定 › 一般 › 鍵盤 › 鍵盤 › Hushkey，並開啟「允許完全取用」。沒有完全取用，鍵盤與 App 就看不到同一個容器。",
                    ok: false
                )
                Button("開啟系統設定") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(QuietButton())
                .padding(.top, 2)
            }
        }
        .onAppear(perform: checkMicrophone)
    }

    private func permissionRow(title: String, detail: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 14))
                .foregroundStyle(ok ? Palette.ink : Palette.dim)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14)).foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var microphoneDetail: String {
        switch micGranted {
        case .some(true): return "已授權。"
        case .some(false): return "未授權：App 內按麥克風不會錄到東西。"
        default: return "還沒問過；第一次按麥克風時會問。"
        }
    }

    private func checkMicrophone() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: micGranted = true
        case .denied: micGranted = false
        default: micGranted = nil
        }
    }

    // MARK: about

    private var aboutCard: some View {
        Card("關於") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                Text("辨識：\(SharedStore.hasModels ? "已安裝" : "未安裝")　整理：\(SharedStore.hasLLM ? LLMPolicy.requestedName : "未安裝")")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                Button(copiedPath ? "已複製路徑" : "複製模型路徑") {
                    UIPasteboard.general.string = SharedStore.modelsRoot.path
                    copiedPath = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedPath = false }
                }
                .buttonStyle(QuietButton())
                Text("所有音訊與逐字稿都留在這台裝置上；App 不連任何伺服器。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
