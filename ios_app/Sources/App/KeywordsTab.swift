import SwiftUI

/// 關鍵字: the proper-noun list.
///
/// The Mac's tab, kept with the same caveat written down where the user can read
/// it: the list is *not* injected into the prompt. A name that is on the list but
/// was not said this time gets pulled into the sentence — measured, not guessed —
/// so the list is a record of how things are spelled, and the recogniser's own
/// answer is what the model works from.
struct KeywordsTab: View {
    @State private var terms: [String] = Keywords.list
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("人名、專案代號等，輸入後按 Enter 或「新增」。")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                Text("這個清單不會被塞進提示詞：沒說到的名字會被模型寫進句子。它記的是這些詞怎麼寫。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("例如：王經理、Notion", text: $draft)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("新增", action: add)
                    .buttonStyle(QuietButton())
                    .frame(width: 84)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if terms.isEmpty {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text("清單是空的")
                        .font(.system(size: 15, weight: .medium, design: .serif))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(terms, id: \.self) { term in
                            HStack(spacing: 10) {
                                Text(term)
                                    .font(.system(size: 15, design: .serif))
                                    .foregroundStyle(Palette.ink)
                                Spacer(minLength: 0)
                                Button {
                                    Keywords.remove(term)
                                    terms = Keywords.list
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.dim)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.bottom, 4)
                }
            }

            Button("全部清空") {
                Keywords.clear()
                terms = []
            }
            .buttonStyle(QuietButton())
            .disabled(terms.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .onAppear { terms = Keywords.list }
    }

    private func add() {
        guard Keywords.add(draft) else {
            draft = ""
            return
        }
        terms = Keywords.list
        draft = ""
    }
}
