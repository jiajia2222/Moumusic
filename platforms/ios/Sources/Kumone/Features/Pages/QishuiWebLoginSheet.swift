#if os(iOS)
import SwiftUI
import WebKit

/// Logs in to Qishui inside an ephemeral WKWebView, then copies only the
/// provider cookies needed by the recommendation API into the app Keychain.
struct QishuiWebLoginSheet: View {
    @EnvironmentObject private var qishui: QishuiSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var isReadingCookies = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if webView == nil {
                    ProgressView("正在打开汽水音乐…")
                }
                QishuiWebView(webView: $webView)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .navigationTitle("扫码登录汽水音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        readCookiesAndSignIn()
                    } label: {
                        if isReadingCookies {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("登录完成")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isReadingCookies || webView == nil)
                }
            }
            .task(id: webView != nil) {
                await monitorCookies()
            }
            .alert("读取登录状态失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "请在页面中完成汽水音乐登录后重试")
            }
        }
    }

    private func readCookiesAndSignIn() {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            errorMessage = "登录页面还没有准备好，请稍后重试"
            return
        }
        isReadingCookies = true
        store.getAllCookies { cookies in
            let domains = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                return domain.contains("douyin.com") || domain.contains("qishui.com")
            }
            var values: [String: String] = [:]
            for cookie in domains {
                values[cookie.name] = cookie.value
            }
            let header = values
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")

            Task { @MainActor in
                do {
                    guard !header.isEmpty else {
                        throw QishuiSessionStore.SessionError.validationFailed
                    }
                    try await qishui.signIn(cookie: header)
                    isReadingCookies = false
                    dismiss()
                } catch {
                    isReadingCookies = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func monitorCookies() async {
        while !Task.isCancelled {
            guard !isReadingCookies,
                  let store = webView?.configuration.websiteDataStore.httpCookieStore else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let header = await cookieHeader(from: store)
            if Self.looksLoggedIn(header) {
                isReadingCookies = true
                do {
                    try await qishui.signIn(cookie: header)
                    isReadingCookies = false
                    dismiss()
                } catch {
                    isReadingCookies = false
                    errorMessage = error.localizedDescription
                }
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func cookieHeader(from store: WKHTTPCookieStore) async -> String {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                var values: [String: String] = [:]
                for cookie in cookies {
                    let domain = cookie.domain.lowercased()
                    guard domain.contains("douyin.com") || domain.contains("qishui.com") else { continue }
                    values[cookie.name] = cookie.value
                }
                continuation.resume(returning: values.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
            }
        }
    }

    private static func looksLoggedIn(_ header: String) -> Bool {
        let values = header.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1]
        }
        let session = values["sessionid"] ?? values["sessionid_ss"] ?? ""
        let identity = values["sid_guard"] ?? values["uid_tt"]
            ?? values["uid_tt_ss"] ?? values["user_unique_id"] ?? ""
        return !session.isEmpty && !identity.isEmpty
    }
}

private struct QishuiWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Do not persist a second copy of the credential in WebKit's website
        // database. QishuiSessionStore owns the validated Cookie in Keychain.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: URL(string: "https://music.douyin.com/")!))
        DispatchQueue.main.async {
            webView = view
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
