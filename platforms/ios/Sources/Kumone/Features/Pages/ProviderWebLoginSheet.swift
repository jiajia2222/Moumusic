#if os(iOS)
import SwiftUI
import WebKit

enum ProviderWebLoginKind: String, Identifiable {
    case qqMusic
    case kugou
    case bilibili

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qqMusic: return "QQ 音乐"
        case .kugou: return "酷狗音乐"
        case .bilibili: return "哔哩哔哩"
        }
    }

    var loginURL: URL {
        switch self {
        case .qqMusic: return URL(string: "https://y.qq.com/portal/login.html")!
        case .kugou: return URL(string: "https://m.kugou.com/loginReg.php?act=login")!
        case .bilibili: return URL(string: "https://passport.bilibili.com/h5-app/passport/login")!
        }
    }

    func accepts(domain: String) -> Bool {
        let value = domain.lowercased()
        switch self {
        case .qqMusic: return value.contains("qq.com")
        case .kugou: return value.contains("kugou.com")
        case .bilibili: return value.contains("bilibili.com")
        }
    }

    func looksLoggedIn(_ header: String) -> Bool {
        let values = header.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1]
        }
        switch self {
        case .qqMusic:
            let uin = values["uin"] ?? values["qqmusic_uin"] ?? ""
            return !uin.isEmpty && uin != "0" &&
                !(values["qqmusic_key"] ?? "").isEmpty
        case .kugou:
            return !(values["token"] ?? "").isEmpty &&
                !(values["userid"] ?? values["kugooid"] ?? "").isEmpty
        case .bilibili:
            return !(values["sessdata"] ?? "").isEmpty &&
                !(values["dedeuserid"] ?? "").isEmpty
        }
    }
}

/// Logs in on the provider's own website and transfers only its Cookie header
/// to the caller. The web view uses an ephemeral store and is never used as a
/// playback or API proxy.
struct ProviderWebLoginSheet: View {
    let provider: ProviderWebLoginKind
    let onSignIn: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var isReadingCookies = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if webView == nil { ProgressView("正在打开\(provider.title)…") }
                ProviderWebView(webView: $webView, url: provider.loginURL)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
            .navigationTitle("扫码登录\(provider.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登录完成") { readCookiesAndSignIn() }
                        .fontWeight(.semibold)
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
                Text(errorMessage ?? "请完成登录后重试")
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
            var values: [String: String] = [:]
            for cookie in cookies where provider.accepts(domain: cookie.domain) {
                values[cookie.name] = cookie.value
            }
            let header = values
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")

            Task { @MainActor in await signIn(cookie: header) }
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
            if provider.looksLoggedIn(header) {
                await signIn(cookie: header)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func cookieHeader(from store: WKHTTPCookieStore) async -> String {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                var values: [String: String] = [:]
                for cookie in cookies where self.provider.accepts(domain: cookie.domain) {
                    values[cookie.name] = cookie.value
                }
                continuation.resume(returning: values.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
            }
        }
    }

    @MainActor
    private func signIn(cookie: String) async {
        guard !isReadingCookies else { return }
        isReadingCookies = true
        do {
            guard !cookie.isEmpty else { throw ProviderLoginError.emptyCookie }
            try await onSignIn(cookie)
            isReadingCookies = false
            dismiss()
        } catch {
            isReadingCookies = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProviderWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { webView = view }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

private enum ProviderLoginError: LocalizedError {
    case emptyCookie
    var errorDescription: String? { "没有读取到有效登录 Cookie，请先完成登录" }
}
#endif
