#!/usr/bin/env python3
"""Source-level adaptation of the iOS 26 app sources for an iOS 15 deployment target.

Runs only on the CI checkout (see prepare.sh). It renames the handful of iOS 16+ API calls to the
stand-ins in Polyfills/IOS15Support.swift, strips pure-decoration modifiers that do not exist on
iOS 15, and patches the few spots that need a different implementation. Every specific patch asserts
that its anchor text exists, so a source change that breaks one fails the build loudly.
"""
import glob
import os
import re
import sys

IOS = sys.argv[1]
SOURCES = glob.glob(os.path.join(IOS, "Sources", "Kumone", "**", "*.swift"), recursive=True) + \
    glob.glob(os.path.join(IOS, "ios", "KumoneIOS", "*.swift"))
POLYFILL_DIR = os.path.join(IOS, "Sources", "Kumone", "_IOS15")


def read(path):
    with open(path, encoding="utf-8-sig", newline="") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def balanced_end(text, open_index):
    """Index just after the parenthesis that closes the one at open_index (strings are skipped)."""
    depth = 0
    i = open_index
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 1
            elif ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    raise ValueError("unbalanced parentheses")


def strip_calls(text, names):
    """Removes `.name(...)` modifier calls (and the whitespace before them)."""
    for name in names:
        token = "." + name + "("
        while True:
            index = text.find(token)
            if index < 0:
                break
            end = balanced_end(text, index + len(token) - 1)
            start = index
            while start > 0 and text[start - 1] in " \t\r\n":
                start -= 1
            text = text[:start] + text[end:]
    return text


def convert_sleep(text):
    pattern = re.compile(r"Task\.sleep\(for: \.(milliseconds|seconds)\(")
    while True:
        match = pattern.search(text)
        if not match:
            return text
        open_index = match.end() - 1
        inner_end = balanced_end(text, open_index)
        expression = text[open_index + 1: inner_end - 1]
        # inner_end points just after the unit's closing paren; the Task.sleep paren follows.
        assert text[inner_end] == ")", text[match.start(): inner_end + 20]
        factor = "1_000_000" if match.group(1) == "milliseconds" else "1_000_000_000"
        replacement = f"Task.sleep(nanoseconds: UInt64(Double({expression}) * {factor}))"
        text = text[: match.start()] + replacement + text[inner_end + 1:]


def convert_regex_literals(text):
    def replace(match):
        pattern = match.group(1)
        groups = len(re.findall(r"(?<!\\)\((?!\?)", pattern))
        if groups == 2:
            kind = "IOS15Regex2"
        elif groups == 3 and "(?:" in pattern:
            kind = "IOS15Regex3Opt"
        elif groups == 3:
            kind = "IOS15Regex3"
        else:
            raise ValueError(f"unsupported regex literal: {pattern}")
        return f'{kind}(#"{pattern}"#)'

    return re.sub(r"#/(.+?)/#", replace, text)


STRIP = [
    "scrollIndicators", "presentationDetents", "presentationDragIndicator", "scrollContentBackground",
    "contentTransition", "scrollBounceBehavior", "searchFocused", "toolbarBackground", "tracking",
    "fontWeight",
]

for path in SOURCES:
    if os.path.dirname(path) == POLYFILL_DIR:
        continue
    original = read(path)
    text = original
    text = re.sub(r"(?<![A-Za-z0-9_])NavigationStack\b", "IOS15NavigationStack", text)
    text = re.sub(r"(?<![A-Za-z0-9_])NavigationPath\b", "IOS15NavigationPath", text)
    text = text.replace("NavigationLink(value:", "IOS15StackLink(value:")
    text = text.replace(".navigationDestination(for:", ".ios15Destination(for:")
    text = text.replace(".navigationDestination(isPresented:", ".ios15Destination(isPresented:")
    text = strip_calls(text, STRIP)
    text = re.sub(r"\.lineLimit\(\d+\.\.\.(\d+)\)", r".lineLimit(\1)", text)
    text = text.replace(", axis: .vertical", "")
    text = convert_sleep(text)
    text = re.sub(r"(?<![A-Za-z0-9_])LabeledContent\(", "IOS15LabeledContent(", text)
    text = re.sub(r"(?<![A-Za-z0-9_])ShareLink\(", "IOS15ShareLink(", text)
    text = re.sub(r"(?<![A-Za-z0-9_])PhotosPickerItem\b", "IOS15PhotosPickerItem", text)
    text = re.sub(r"(?<![A-Za-z0-9_])PhotosPicker\(", "IOS15PhotosPicker(", text)
    text = re.sub(r"(?<![A-Za-z0-9_])AnyShape\b(?!Style)", "IOS15AnyShape", text)
    text = re.sub(r"(?<![A-Za-z0-9_])ImageRenderer\(", "IOS15ImageRenderer(", text)
    text = text.replace('Locale.current.language.languageCode?.identifier == "zh"', 'Locale.current.languageCode == "zh"')
    if "#/" in text:
        text = convert_regex_literals(text)
    if text != original:
        write(path, text)


def patch(relative, pairs):
    path = os.path.join(IOS, "Sources", "Kumone", relative)
    text = read(path)
    crlf = "\r\n" in text
    text = text.replace("\r\n", "\n")
    for old, new in pairs:
        assert old in text, f"{relative}: anchor not found: {old[:70]!r}"
        text = text.replace(old, new, 1)
    if crlf:
        text = text.replace("\n", "\r\n")
    write(path, text)


# Theme: the toolbar-background fallback has no iOS 15 counterpart.
patch("DesignSystem/Theme.swift", [
    ("            toolbarBackground(.hidden, for: .navigationBar)\n", "            self\n"),
])

# Main window: the wallpaper sits behind the navigation content (containerBackground is iOS 17+).
patch("Features/IOSMainWindow.swift", [
    ("""                .containerBackground(for: .navigation) {
                    wallpaperLayer
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
""", """                .background {
                    wallpaperLayer
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
"""),
])

# Photos import: no Transferable on iOS 15.
patch("Core/Storage/BackgroundImageStore.swift", [
    ("import CoreTransferable\n", ""),
    ("        return try await selection.loadTransferable(type: ImageTransfer.self)?.data\n", "        return nil\n"),
    ("""private struct ImageTransfer: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ImageTransfer(data: data)
        }
    }
}
""", ""),
])

# Shader wallpapers need iOS 17.
patch("Core/Storage/DynamicWallpaperStore.swift", [
    ("    private var shader: some View {\n        switch kind {\n",
     "    private var shader: some View {\n        if #available(iOS 17.0, *) {\n        switch kind {\n"),
])
text = read(os.path.join(IOS, "Sources", "Kumone", "Core/Storage/DynamicWallpaperStore.swift"))
marker = "        case .grainGradient: SWGrainGradient()\n        }\n"
assert marker in text, "DynamicWallpaperStore: end of shader switch not found"
text = text.replace(marker, marker + "        } else {\n            Color.black\n        }\n", 1)
write(os.path.join(IOS, "Sources", "Kumone", "Core/Storage/DynamicWallpaperStore.swift"), text)

# Bilibili player: no ViewThatFits / requestGeometryUpdate on iOS 15.
patch("Features/Pages/BilibiliNativePlayer.swift", [
    ("""                ViewThatFits(in: .horizontal) {
                    controlRow(compact: false)
                    controlRow(compact: true)
                }""", """                GeometryReader { proxy in
                    if proxy.size.width > 440 {
                        controlRow(compact: false)
                    } else {
                        controlRow(compact: true)
                    }
                }
                .frame(height: 40)"""),
    ("""        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }""",
     """        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        } else {
            let value = landscape ? UIInterfaceOrientation.landscapeRight.rawValue : UIInterfaceOrientation.portrait.rawValue
            UIDevice.current.setValue(value, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }"""),
])

# Ruby text: the Layout protocol is iOS 16; size the canvas from the proposed width instead.
ruby_path = os.path.join(IOS, "Sources", "Kumone", "DesignSystem", "RubyText.swift")
ruby = read(ruby_path)
start = ruby.index("private struct RubyTextLayout: Layout {")
end = ruby.index("private extension Font.Weight {")
ruby = ruby[:start] + '''private struct RubyTextLayout<Content: View>: View {
    private let box: AttributedBox
    private let content: Content
    @State private var height: CGFloat = 24

    init(attributed: NSAttributedString, @ViewBuilder content: () -> Content) {
        box = AttributedBox(attributed)
        self.content = content()
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(
                GeometryReader { proxy in
                    content
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .onAppear { update(width: proxy.size.width) }
                        .onChange(of: proxy.size.width) { update(width: $0) }
                }
            )
    }

    private func update(width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        let fitted = RubyAttributedString.fittedSize(box.string, width: width)
        let newHeight = ceil(fitted.height)
        if abs(newHeight - height) > 0.5 { height = newHeight }
    }
}

''' + ruby[end:]
write(ruby_path, ruby)
print("iOS 15 patches applied")
