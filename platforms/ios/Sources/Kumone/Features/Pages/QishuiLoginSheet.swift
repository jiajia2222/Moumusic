import SwiftUI

struct QishuiLoginSheet: View {
    @EnvironmentObject private var qishui: QishuiSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
#if os(iOS)
    @State private var showWebLogin = false
#endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("使用汽水音乐 Cookie 登录", systemImage: "person.badge.key.fill")
                            .font(.headline)

                        Text("先在 music.douyin.com 登录汽水音乐，再复制浏览器中的完整 Cookie 粘贴到这里。Moumusic 不接收密码，也不会把 Cookie 上传到第三方服务器。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

#if os(iOS)
                        Button {
                            showWebLogin = true
                        } label: {
                            Label("打开汽水音乐扫码登录", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
#endif

                        TextEditor(text: $cookie)
                            .frame(minHeight: 110)
                            .font(.system(.footnote, design: .monospaced))
                            .privacySensitive()
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
                            }
                            .accessibilityLabel("汽水音乐 Cookie 输入框")
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    Button {
                        signIn()
                    } label: {
                        HStack {
                            Spacer()
                            if isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在验证…")
                            } else {
                                Text("验证并登录")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSigningIn || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
                }

                if qishui.isLoggedIn {
                    Section("当前状态") {
                        Label(qishui.profileName ?? "汽水音乐已登录", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("汽水音乐登录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("登录失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "请稍后重试")
            }
#if os(iOS)
            .sheet(isPresented: $showWebLogin) {
                QishuiWebLoginSheet()
                    .environmentObject(qishui)
            }
#endif
        }
    }

    private func signIn() {
        isSigningIn = true
        Task {
            do {
                try await qishui.signIn(cookie: cookie)
                cookie = ""
                isSigningIn = false
                dismiss()
            } catch {
                isSigningIn = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
