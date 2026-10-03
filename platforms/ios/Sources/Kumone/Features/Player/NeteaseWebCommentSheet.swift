#if os(iOS)
import SwiftUI
import WebKit

/// NetEase answers app-side comment posts from this device with "请切换设备后重试" (risk control).
/// The official web page signs the request with its own anti-cheat script (and shows the slider
/// verification when needed), so posting there works: the page opens signed in with the account.
struct NeteaseWebCommentSheet: View {
    let songID: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NeteaseSongWebView(songID: songID)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("网页版评论")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
        }
    }
}

private struct NeteaseSongWebView: UIViewRepresentable {
    let songID: Int

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let store = configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for name in ["MUSIC_U", "__csrf"] {
            guard let value = NeteaseClient.shared.cookie(named: name),
                  let cookie = HTTPCookie(properties: [
                    .domain: ".music.163.com", .path: "/", .name: name, .value: value, .secure: "TRUE",
                    .expires: Date().addingTimeInterval(30 * 24 * 3600)
                  ]) else { continue }
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            if let url = URL(string: "https://music.163.com/song?id=\(songID)") {
                web.load(URLRequest(url: url))
            }
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
