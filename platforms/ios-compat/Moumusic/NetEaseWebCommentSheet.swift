import SwiftUI
import WebKit

/// 网易云对本机的评论请求常回「请切换设备后重试」（风控）。官方网页自带签名与验证码流程，
/// 带着账号登录态打开歌曲页后可以直接在网页里发表评论。
struct NetEaseWebCommentSheet: View {
    let songID: Int
    @Environment(\.presentationMode) private var presentation

    var body: some View {
        NavigationView {
            NetEaseSongWebView(songID: songID)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("网页版评论")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { presentation.wrappedValue.dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

private struct NetEaseSongWebView: UIViewRepresentable {
    let songID: Int

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let store = configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for (name, value) in NetEaseAPI.shared.webSessionCookies() {
            guard let cookie = HTTPCookie(properties: [
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
