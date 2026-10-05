#if os(iOS)
import SwiftUI
import WebKit

/// The original Apple Music-like Lyrics player (https://github.com/amll-dev/applemusic-like-lyrics, AGPL-3.0), running in a
/// web view. The lyric lines and clock samples are pushed in; the page animates with AMLL's own spring layout, blur and
/// word highlight and reports taps on a line back so the song can jump there.
struct AMLLWebLyricsView: View {
    let lyrics: ParsedLyrics

    @EnvironmentObject private var settings: SettingsManager

    /// The page relies on CSS nesting and registered custom properties (WebKit 16.4+).
    static var isSupported: Bool {
        if #available(iOS 16.4, *) { return true }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let screen = UIScreen.main.bounds.width
            // On a portrait phone the lyrics use the whole screen width, whatever margin the page around them has;
            // beside the artwork (landscape, iPad) the column keeps its own width.
            let fullWidth = screen < 500 && frame.width > screen * 0.7
            let left = fullWidth ? max(0, frame.minX) : 0
            let right = fullWidth ? max(0, screen - frame.maxX) : 0
            let width = geometry.size.width + left + right
            AMLLWebRepresentable(
                lyrics: lyrics,
                showsTranslation: settings.showLyricsTranslation,
                showsRomaji: settings.lyricsAnnotation == .romaji,
                fontSize: max(26, min(44, width * 0.095))
            )
            .frame(width: width, height: geometry.size.height)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .offset(x: -left)
        }
    }
}

private struct AMLLWebRepresentable: UIViewRepresentable {
    let lyrics: ParsedLyrics
    let showsTranslation: Bool
    let showsRomaji: Bool
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // WebKit paces page animation near 60 fps by default (requestAnimationFrame included). The lyrics should follow the
        // display, 120 Hz on ProMotion phones, so that pacing feature is switched off. This goes through WebKit's internal
        // feature switch (not public API), so every step is checked and the outcome is logged.
        let switched = Self.disableNear60FPSPacing(configuration.preferences)
        Task { @MainActor in
            DiagnosticLogStore.shared.append(
                level: .info, category: "AMLL", message: "歌词帧率设置",
                detail: "60 帧限制已解除：\(switched)，屏幕最高 \(UIScreen.main.maximumFramesPerSecond) Hz")
        }
        configuration.userContentController.add(WeakScriptHandler(context.coordinator), name: "amll")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        // AMLL scrolls and flicks the lyrics itself from the touch events.
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.attach(web)
        if let url = Bundle.module.url(forResource: "AMLLLyricsPage", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    /// `WKPreferences` keeps an internal list of feature flags; "PreferPageRenderingUpdatesNear60FPSEnabled" is the one that
    /// holds page animation near 60 fps.
    private static func disableNear60FPSPacing(_ preferences: WKPreferences) -> Bool {
        let featuresSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard WKPreferences.responds(to: featuresSelector), preferences.responds(to: setSelector),
              let list = (WKPreferences.self as AnyObject).perform(featuresSelector)?.takeUnretainedValue() as? [AnyObject]
        else { return false }
        for feature in list {
            guard let key = feature.value(forKey: "key") as? String,
                  key == "PreferPageRenderingUpdatesNear60FPSEnabled" else { continue }
            typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
            let implementation = preferences.method(for: setSelector)
            unsafeBitCast(implementation, to: SetEnabled.self)(preferences, setSelector, false, feature)
            return true
        }
        return false
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.update(lyrics: lyrics, showsTranslation: showsTranslation, showsRomaji: showsRomaji,
                                   fontSize: fontSize)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        private weak var web: WKWebView?
        private var ready = false
        private var loadedSignature: Int?
        private var pending: (lyrics: ParsedLyrics, translation: Bool, romaji: Bool, signature: Int)?
        private var fontSize: CGFloat = 30
        private var timer: Timer?

        func attach(_ web: WKWebView) {
            self.web = web
            // The page extrapolates the clock between samples, so ten a second keep it exact without a call per frame.
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushClock() }
            }
        }

        func detach() {
            timer?.invalidate()
            timer = nil
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "amll")
        }

        func update(lyrics: ParsedLyrics, showsTranslation: Bool, showsRomaji: Bool, fontSize: CGFloat) {
            var hasher = Hasher()
            hasher.combine(lyrics)
            hasher.combine(showsTranslation)
            hasher.combine(showsRomaji)
            let signature = hasher.finalize()
            if abs(fontSize - self.fontSize) > 0.5 {
                self.fontSize = fontSize
                if ready { run("AMLLBridge.setFontSize(\(fontSize))") }
            }
            guard signature != loadedSignature else { return }
            pending = (lyrics, showsTranslation, showsRomaji, signature)
            flushPending()
        }

        private func flushPending() {
            guard ready, let pending else { return }
            self.pending = nil
            loadedSignature = pending.signature
            let payload = Self.payload(for: pending.lyrics, translation: pending.translation, romaji: pending.romaji)
            let ms = Int(currentSeconds() * 1000)
            run("AMLLBridge.setFontSize(\(fontSize)); AMLLBridge.load(\(payload), \(ms))")
            pushClock()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "moumusic.debugAMLL") { scheduleDiagnostics() }
            #endif
        }

        #if DEBUG
        /// Debug only: what the page really rendered (text code points, font, size, errors), into the diagnostic log.
        private func scheduleDiagnostics() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                let script = """
                (function(){
                  const line = document.querySelector('[class*="lyricMainLine"]');
                  const span = line && line.querySelector('span');
                  const rect = line ? line.getBoundingClientRect() : null;
                  return JSON.stringify({
                    ua: navigator.userAgent, w: innerWidth, h: innerHeight,
                    family: span ? getComputedStyle(span).fontFamily : null,
                    size: span ? getComputedStyle(span).fontSize : null,
                    text: line ? line.textContent.slice(0, 24) : null,
                    codes: line ? Array.from(line.textContent.slice(0, 6)).map(c => c.codePointAt(0).toString(16)) : null,
                    lines: document.querySelectorAll('[class*="lyricLine"]').length,
                    rect: rect ? [Math.round(rect.width), Math.round(rect.height)] : null,
                    errors: window.__amllErrors || []
                  });
                })()
                """
                self?.web?.evaluateJavaScript(script) { result, error in
                    let text = (result as? String) ?? "error: \(String(describing: error))"
                    DiagnosticLogStore.shared.append(level: .info, category: "AMLL", message: "页面诊断", detail: text)
                }
            }
        }
        #endif

        private func currentSeconds() -> TimeInterval {
            PlayerService.shared.livePlaybackTime + SettingsManager.shared.effectiveLyricsOffset
        }

        private func pushClock() {
            guard ready else { return }
            let player = PlayerService.shared
            let ms = Int(currentSeconds() * 1000)
            run("AMLLBridge.sync(\(ms), \(player.isPlaying), \(player.playbackRate))")
        }

        private func run(_ script: String) {
            web?.evaluateJavaScript(script, completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                flushPending()
            case "fps":
                let fps = (body["fps"] as? NSNumber)?.intValue ?? 0
                DiagnosticLogStore.shared.append(level: .info, category: "AMLL", message: "歌词页实测帧率",
                                                 detail: "\(fps) fps（屏幕最高 \(UIScreen.main.maximumFramesPerSecond) Hz）")
            case "seek":
                guard let milliseconds = (body["time"] as? NSNumber)?.doubleValue else { return }
                // The page works in lyric time (clock + offset): undo the offset to get the playback position.
                PlayerService.shared.seek(to: max(0, milliseconds / 1000 - SettingsManager.shared.effectiveLyricsOffset))
            default:
                break
            }
        }

        /// The lyric lines in AMLL's `LyricLine` shape, as a JavaScript string literal holding the JSON.
        private static func payload(for lyrics: ParsedLyrics, translation: Bool, romaji: Bool) -> String {
            let lines = lyrics.lines
            var output: [[String: Any]] = []
            for (index, line) in lines.enumerated() {
                let startMs = Int((line.time * 1000).rounded())
                let nextStart = index + 1 < lines.count ? lines[index + 1].time : line.time + 6
                var words: [[String: Any]] = []
                if line.hasVerbatimTimings, let timed = line.words {
                    for (position, word) in timed.enumerated() {
                        let start = Int((word.start * 1000).rounded())
                        let following = position + 1 < timed.count ? timed[position + 1].start : word.end
                        let end = max(start + 1, Int((max(word.end, word.duration > 0 ? word.end : following) * 1000).rounded()))
                        words.append(["startTime": start, "endTime": end, "word": word.text])
                    }
                } else {
                    // Line-timed lyrics: one word spanning the line, which AMLL shows as a plain (non-karaoke) line.
                    let end = Int((max(nextStart, line.time + 1) * 1000).rounded())
                    words.append(["startTime": startMs, "endTime": end, "word": line.text.isEmpty ? " " : line.text])
                }
                let endMs = (words.last?["endTime"] as? Int) ?? startMs + 1
                output.append([
                    "words": words,
                    "translatedLyric": translation ? (line.translation ?? "") : "",
                    "romanLyric": romaji ? (line.romaji ?? "") : "",
                    "startTime": startMs,
                    "endTime": max(endMs, startMs + 1),
                    "isBG": false,
                    "isDuet": false,
                ])
            }
            guard let data = try? JSONSerialization.data(withJSONObject: output),
                  let json = String(data: data, encoding: .utf8),
                  let literal = try? JSONEncoder().encode(json),
                  let text = String(data: literal, encoding: .utf8) else { return "\"[]\"" }
            return text
        }
    }
}

/// WKUserContentController retains its handlers; this keeps the coordinator from being kept alive by it.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
#endif
