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
    @State private var translate = Preferences.translate
    @State private var stages = Preferences.refineStages
    @State private var refine = SharedStore.refineEnabled
    @State private var micGranted: Bool?
    @State private var copiedPath = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                translateCard
                cleanupCard
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
            refine = SharedStore.refineEnabled
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
             caption: "段數是模型要跑幾遍：0 讓引擎依長度自己決定，1 直接濃縮，2 先理解再濃縮。") {
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
            }
        }
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
