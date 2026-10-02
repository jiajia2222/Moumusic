import SwiftUI
import UIKit
import WebKit

/// 个人资料卡片：加载内置 XProfile.html（与 Beans 2.0.2 同款），
/// 通过 window.tm 桥接把头像/背景存到本机，并把设置同步到 Moumusic 服务端。
@MainActor
struct XProfileCardView: View {
    @ObservedObject private var reporter = DeviceReporter.shared
    @ObservedObject private var stats = ListeningStatsStore.shared
    @ObservedObject private var remote = RemoteControlStore.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            if remote.announcementEnabled, !remote.announcementText.isEmpty {
                Text(remote.announcementText)
                    .font(.footnote)
                    .foregroundColor(Color(hex: remote.announcementTextColorHex) ?? .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            XProfileWebView(
                displayID: reporter.displayID,
                exclusive: !reporter.exclusiveID.isEmpty,
                badgeStyle: reporter.badgeStyle.rawValue,
                listeningDuration: stats.formattedDuration
            )
            .frame(height: 470)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .task {
            await RemoteControlStore.shared.refreshIfNeeded()
        }
    }
}

struct XProfileWebView: UIViewRepresentable {
    let displayID: String
    let exclusive: Bool
    let badgeStyle: String
    let listeningDuration: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let bridge = """
        (function(){
          function call(op, payload){ return window.webkit.messageHandlers.tm.postMessage(Object.assign({op:op}, payload)); }
          window.tm = {
            saveFile: function(name, data){ return call('saveFile', {name:name, data:data}); },
            loadFile: function(name){ return call('loadFile', {name:name}); },
            sync: function(json){ call('sync', {json:json}); }
          };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "tm")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "XProfile", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.pendingIdentity = (displayID, exclusive, badgeStyle)
        c.pendingDuration = listeningDuration
        c.pushState()
    }

    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        weak var web: WKWebView?
        var pendingIdentity: (String, Bool, String)?
        var pendingDuration = ""
        private var loaded = false
        private var syncWork: DispatchWorkItem?

        private static var storeDir: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = base.appendingPathComponent("XProfile", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }()

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            pushState()
        }

        func pushState() {
            guard loaded, let web = web else { return }
            if let (id, exclusive, badge) = pendingIdentity, !id.isEmpty {
                let payload: [String: Any] = ["displayId": id, "exclusive": exclusive, "badgeStyle": badge]
                if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                    web.evaluateJavaScript("window.__moumusicSetIdentity && window.__moumusicSetIdentity(\(json))", completionHandler: nil)
                }
            }
            if !pendingDuration.isEmpty {
                let payload = ["listeningDuration": pendingDuration]
                if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                    web.evaluateJavaScript("window.__beansUpdateStats && window.__beansUpdateStats(\(json))", completionHandler: nil)
                }
            }
        }

        private func fileURL(for name: String) -> URL? {
            let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            guard !safe.isEmpty, !safe.hasPrefix(".") else { return nil }
            return Self.storeDir.appendingPathComponent(safe)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
                replyHandler(nil, "bad message"); return
            }
            switch op {
            case "saveFile":
                guard let name = body["name"] as? String, let data = body["data"] as? String, let url = fileURL(for: name) else {
                    replyHandler(nil, "bad file"); return
                }
                do {
                    try data.data(using: .utf8)?.write(to: url, options: .atomic)
                    replyHandler(true, nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            case "loadFile":
                guard let name = body["name"] as? String, let url = fileURL(for: name),
                      let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                    replyHandler(NSNull(), nil); return
                }
                replyHandler(text, nil)
            case "sync":
                if let json = body["json"] as? String { scheduleSync(json) }
                replyHandler(true, nil)
            default:
                replyHandler(nil, "unknown op")
            }
        }

        /// 设置变动较频繁（滑块拖动），延迟 2 秒合并后再上传。
        private func scheduleSync(_ json: String) {
            syncWork?.cancel()
            let work = DispatchWorkItem {
                guard let data = json.data(using: .utf8),
                      let profile = try? JSONSerialization.jsonObject(with: data) else { return }
                let body: [String: Any] = ["user_id": StableDeviceID.value, "profile": profile]
                URLSession.shared.dataTask(with: MoumusicServer.request("profile", method: "PUT", json: body)).resume()
            }
            syncWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }
}
