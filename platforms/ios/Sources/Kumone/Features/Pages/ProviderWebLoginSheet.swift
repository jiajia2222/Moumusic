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
        // The old /portal/login.html route now returns 404.  Keep the web
        // fallback on the live QQ Music entry page; the primary iOS button
        // uses QQMusicQRCodeLoginSheet and does not depend on this route.
        case .qqMusic: return URL(string: "https://y.qq.com/")!
        case .kugou: return URL(string: "https://m3ws.kugou.com/loginReg.php?act=login")!
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

    /// Adds the 	oken / userid fields the Kugou client code expects when the web page
    /// only provided 	 / KugooID.
    func normalized(_ header: String) -> String {
        guard self == .kugou else { return header }
        var values: [String: String] = [:]
        for item in header.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { values[pair[0].lowercased()] = pair[1] }
        }
        var result = header
        if values["token"] == nil, let t = values["t"], t.count >= 8 { result += "; token=\(t)" }
        if values["userid"] == nil, let id = values["kugooid"] { result += "; userid=\(id)" }
        return result
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
            let credential = values["qqmusic_key"] ?? values["qm_keyst"] ?? values["p_skey"]
                ?? values["skey"] ?? values["psrf_access_token"] ?? values["psrf_qq_access_token"] ?? ""
            // QQ rotates the cookie name used by its web player. Do not require
            // one legacy key, otherwise a successful QR/phone login is shown
            // as “credential acquisition failed”.
            let openID = values["psrf_qqopenid"] ?? ""
            return (!uin.isEmpty && uin != "0" && !credential.isEmpty) ||
                (!credential.isEmpty && !openID.isEmpty)
        case .kugou:
            // The web page keeps the login token in the short cookie 	 (next to KugooID).
            let webToken = (values["t"] ?? "").count >= 8 ? (values["t"] ?? "") : ""
            let token = values["token"] ?? values["login_token"] ?? values["kugou_token"] ?? values["kg_token"] ?? webToken
            let identity = values["userid"] ?? values["user_id"] ?? values["kugooid"]
                ?? values["kugoo_id"] ?? values["kg_mid"] ?? values["mid"] ?? ""
            return !token.isEmpty && !identity.isEmpty && identity != "0"
        case .bilibili:
            return !(values["sessdata"] ?? "").isEmpty &&
                !(values["dedeuserid"] ?? "").isEmpty
        }
    }
}

/// Logs in on the provider's own website and transfers only its Cookie header
/// to the caller. The WebKit store is isolated from Safari; the app copies
/// only the provider session into its Keychain and never uses this view as an
/// API or playback proxy.
struct ProviderWebLoginSheet: View {
    let provider: ProviderWebLoginKind
    let onSignIn: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var isReadingCookies = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if webView == nil { ProgressView("正在打开\(provider.title)…") }
                ProviderWebView(webView: $webView, url: provider.loginURL)
                    .ignoresSafeArea(.container, edges: .bottom)

                if let statusMessage {
                    VStack {
                        Spacer()
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.green.opacity(0.28), lineWidth: 1))
                            .padding(.bottom, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("网页登录 / 手机号登录\(provider.title)")
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
        guard !isReadingCookies else { return }
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
            let snapshot = values
            let header = values
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "; ")

            Task { @MainActor in
                guard provider.looksLoggedIn(header) else {
                    let names = header.split(separator: ";").compactMap { $0.split(separator: "=").first.map { String($0).trimmingCharacters(in: .whitespaces) } }.joined(separator: ",")
                    DiagnosticLogStore.shared.append(level: .warning, category: "\(provider.title)登录", message: "网页登录未检测到登录状态", detail: "cookies=\(names) | t.len=\(snapshot["t"]?.count ?? -1) KugooID=\(snapshot["KugooID"] ?? "-") kg_login=\(snapshot["kg_login"] ?? "-") UserName.len=\(snapshot["UserName"]?.count ?? -1)")
                    isReadingCookies = false
                    errorMessage = "还没有检测到\(provider.title)登录状态，请先完成手机号/网页登录后再点“登录完成”"
                    return
                }
                await signIn(cookie: provider.normalized(header))
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
            if provider.looksLoggedIn(header) {
                await signIn(cookie: provider.normalized(header))
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
        isReadingCookies = true
        do {
            guard !cookie.isEmpty else { throw ProviderLoginError.emptyCookie }
            try await onSignIn(cookie)
            isReadingCookies = false
            statusMessage = "\(provider.title)登录成功"
            ToastCenter.shared.show("\(provider.title)登录成功")
            dismiss()
        } catch {
            isReadingCookies = false
            DiagnosticLogStore.shared.append(level: .error, category: "\(provider.title)登录", message: "网页登录会话保存失败", detail: "\(error)")
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProviderWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // QQ/Kugou/Bilibili phone-login flows use redirects and local storage
        // before setting the final account cookie. A persistent app-local store
        // is required for those flows to survive the redirect. The actual
        // playback clients still receive only the normalized cookie header.
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = context.coordinator
        // y.qq.com serves a mobile page without a login entry; ask for the desktop site.
        if url.host?.contains("y.qq.com") == true {
            view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
            configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { webView = view }
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ view: WKWebView, context: Context) {}

    /// iOS may kill the web content process while the app is in the background (for
    /// example while checking a verification code elsewhere). Reload the page the
    /// user was on instead of leaving a blank view.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastURL: URL?

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let url = webView.url { lastURL = url }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let url = lastURL ?? webView.url { webView.load(URLRequest(url: url)) } else { webView.reload() }
        }
    }
}

private enum ProviderLoginError: LocalizedError {
    case emptyCookie
    var errorDescription: String? { "没有读取到有效登录 Cookie，请先完成登录" }
}
#endif
