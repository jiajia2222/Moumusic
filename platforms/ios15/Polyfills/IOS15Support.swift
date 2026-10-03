// iOS 15 stand-ins for SwiftUI / Foundation API that arrived in iOS 16+. Compiled only into the
// iOS 15 build (copied next to the app sources by platforms/ios15/prepare.sh); the iOS 26 app never sees it.
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - NavigationStack / NavigationPath on NavigationView

struct IOS15NavigationPath {
    private(set) var items: [AnyHashable] = []

    init() {}
    init<S: Sequence>(_ elements: S) where S.Element: Hashable { items = elements.map { AnyHashable($0) } }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    mutating func append<V: Hashable>(_ value: V) { items.append(AnyHashable(value)) }
    mutating func removeLast(_ k: Int = 1) { items.removeLast(min(max(k, 0), items.count)) }
    mutating func truncate(to depth: Int) { if items.count > depth { items.removeLast(items.count - depth) } }
}

final class IOS15StackRouter: ObservableObject {
    private var builders: [ObjectIdentifier: (AnyHashable) -> AnyView] = [:]

    func register<D: Hashable, C: View>(_ type: D.Type, _ destination: @escaping (D) -> C) {
        builders[ObjectIdentifier(type)] = { item in
            guard let value = item.base as? D else { return AnyView(EmptyView()) }
            return AnyView(destination(value))
        }
    }

    func view(for item: AnyHashable) -> AnyView? {
        builders[ObjectIdentifier(type(of: item.base))]?(item)
    }
}

private struct IOS15PathKey: EnvironmentKey {
    static let defaultValue: Binding<IOS15NavigationPath>? = nil
}

extension EnvironmentValues {
    fileprivate var ios15Path: Binding<IOS15NavigationPath>? {
        get { self[IOS15PathKey.self] }
        set { self[IOS15PathKey.self] = newValue }
    }
}

struct IOS15NavigationStack<Root: View>: View {
    @StateObject private var router = IOS15StackRouter()
    @State private var internalPath = IOS15NavigationPath()
    private let externalPath: Binding<IOS15NavigationPath>?
    private let root: Root

    init(@ViewBuilder root: () -> Root) {
        self.root = root()
        self.externalPath = nil
    }

    init(path: Binding<IOS15NavigationPath>, @ViewBuilder root: () -> Root) {
        self.root = root()
        self.externalPath = path
    }

    private var pathBinding: Binding<IOS15NavigationPath> { externalPath ?? $internalPath }

    var body: some View {
        NavigationView {
            IOS15StackLevel(depth: 0, content: AnyView(root))
        }
        .navigationViewStyle(.stack)
        .environmentObject(router)
        .environment(\.ios15Path, pathBinding)
    }
}

private struct IOS15StackLevel: View {
    let depth: Int
    let content: AnyView
    @Environment(\.ios15Path) private var path
    @EnvironmentObject private var router: IOS15StackRouter

    var body: some View {
        content.background(
            NavigationLink(
                isActive: Binding(
                    get: { (path?.wrappedValue.count ?? 0) > depth },
                    set: { active in
                        guard !active, let path, path.wrappedValue.count > depth else { return }
                        var value = path.wrappedValue
                        value.truncate(to: depth)
                        path.wrappedValue = value
                    }
                ),
                destination: { next },
                label: { EmptyView() }
            )
            .hidden()
        )
    }

    @ViewBuilder private var next: some View {
        if let items = path?.wrappedValue.items, depth < items.count, let view = router.view(for: items[depth]) {
            IOS15StackLevel(depth: depth + 1, content: view)
        } else {
            EmptyView()
        }
    }
}

struct IOS15StackLink<Label: View, V: Hashable>: View {
    let value: V?
    let label: Label
    @Environment(\.ios15Path) private var path

    init(value: V?, @ViewBuilder label: () -> Label) {
        self.value = value
        self.label = label()
    }

    var body: some View {
        Button {
            guard let value, let path else { return }
            path.wrappedValue.append(value)
        } label: { label }
    }
}

private struct IOS15DestinationModifier<D: Hashable, C: View>: ViewModifier {
    @EnvironmentObject private var router: IOS15StackRouter
    let destination: (D) -> C

    func body(content: Content) -> some View {
        let _ = router.register(D.self, destination)
        return content
    }
}

extension View {
    func ios15Destination<D: Hashable, C: View>(for type: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        modifier(IOS15DestinationModifier(destination: destination))
    }

    func ios15Destination<C: View>(isPresented: Binding<Bool>, @ViewBuilder destination: () -> C) -> some View {
        background(
            NavigationLink(isActive: isPresented, destination: destination, label: { EmptyView() }).hidden()
        )
    }
}

// MARK: - LabeledContent

struct IOS15LabeledContent<Label: View, Content: View>: View {
    let label: Label
    let content: Content

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    var body: some View {
        HStack {
            label
            Spacer(minLength: 12)
            content.foregroundColor(.secondary)
        }
    }
}

extension IOS15LabeledContent where Label == Text, Content == Text {
    init<S1: StringProtocol, S2: StringProtocol>(_ title: S1, value: S2) {
        self.init(content: { Text(String(value)) }, label: { Text(String(title)) })
    }
}

extension IOS15LabeledContent where Label == Text {
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content, label: { Text(String(title)) })
    }
}

// MARK: - ShareLink

struct IOS15ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct IOS15ShareLink<Label: View>: View {
    private let items: [Any]
    private let label: Label
    @State private var showing = false

    init(item: URL, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        items = [item]
        self.label = label()
    }

    init(item: String, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        items = [item]
        self.label = label()
    }

    var body: some View {
        Button { showing = true } label: { label }
            .sheet(isPresented: $showing) { IOS15ActivitySheet(items: items) }
    }
}

extension IOS15ShareLink where Label == SwiftUI.Label<Text, Image> {
    init(item: URL) { self.init(item: item) { SwiftUI.Label("分享", systemImage: "square.and.arrow.up") } }
    init(item: String) { self.init(item: item) { SwiftUI.Label("分享", systemImage: "square.and.arrow.up") } }
}

// MARK: - PhotosPicker

final class IOS15PhotosPickerItem: Equatable {
    let provider: NSItemProvider
    init(provider: NSItemProvider) { self.provider = provider }
    static func == (lhs: IOS15PhotosPickerItem, rhs: IOS15PhotosPickerItem) -> Bool { lhs === rhs }

    var supportedContentTypes: [UTType] { provider.registeredTypeIdentifiers.compactMap { UTType($0) } }

    func loadTransferable(type: Data.Type) async throws -> Data? {
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true || UTType($0)?.conforms(to: .movie) == true
        } ?? provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }
}

struct IOS15PHPicker: UIViewControllerRepresentable {
    let filter: PHPickerFilter?
    let onPick: (IOS15PhotosPickerItem?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = filter
        configuration.selectionLimit = 1
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (IOS15PhotosPickerItem?) -> Void
        init(onPick: @escaping (IOS15PhotosPickerItem?) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPick(results.first.map { IOS15PhotosPickerItem(provider: $0.itemProvider) })
        }
    }
}

struct IOS15PhotosPicker<Label: View>: View {
    @Binding var selection: IOS15PhotosPickerItem?
    let filter: PHPickerFilter?
    let label: Label
    @State private var presenting = false

    init(selection: Binding<IOS15PhotosPickerItem?>, matching filter: PHPickerFilter? = nil,
         photoLibrary: PHPhotoLibrary? = nil, @ViewBuilder label: () -> Label) {
        _selection = selection
        self.filter = filter
        self.label = label()
    }

    var body: some View {
        Button { presenting = true } label: { label }
            .sheet(isPresented: $presenting) {
                IOS15PHPicker(filter: filter) { item in
                    if let item { selection = item }
                    presenting = false
                }
            }
    }
}

// MARK: - AnyShape / ImageRenderer

struct IOS15AnyShape: Shape {
    private let builder: (CGRect) -> Path
    init<S: Shape>(_ shape: S) { builder = { shape.path(in: $0) } }
    func path(in rect: CGRect) -> Path { builder(rect) }
}

@MainActor
final class IOS15ImageRenderer<Content: View> {
    private let content: Content
    var scale: CGFloat = 1

    init(content: Content) { self.content = content }

    var uiImage: UIImage? {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        let size = host.sizeThatFits(in: CGSize(width: 4000, height: 4000))
        guard size.width > 0, size.height > 0 else { return nil }
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }
}

// MARK: - Regex stand-ins (NSRegularExpression behind the Swift Regex call shapes the lyric parsers use)

struct IOS15Regex2 { let regex: NSRegularExpression; init(_ pattern: String) { regex = try! NSRegularExpression(pattern: pattern) } }
struct IOS15Regex3 { let regex: NSRegularExpression; init(_ pattern: String) { regex = try! NSRegularExpression(pattern: pattern) } }
struct IOS15Regex3Opt { let regex: NSRegularExpression; init(_ pattern: String) { regex = try! NSRegularExpression(pattern: pattern) } }

struct IOS15Match2 { let output: (Substring, Substring, Substring); let range: Range<String.Index> }
struct IOS15Match3 { let output: (Substring, Substring, Substring, Substring); let range: Range<String.Index> }
struct IOS15Match3Opt { let output: (Substring, Substring, Substring, Substring?); let range: Range<String.Index> }

private func ios15Groups<S: StringProtocol>(_ string: S, _ regex: NSRegularExpression, first: Bool) -> [[Range<String.Index>?]] where S.SubSequence == Substring {
    let text = String(string)
    let full = NSRange(location: 0, length: text.utf16.count)
    let results = first ? [regex.firstMatch(in: text, range: full)].compactMap { $0 } : regex.matches(in: text, range: full)
    return results.map { result in
        (0..<result.numberOfRanges).map { index -> Range<String.Index>? in
            let nsRange = result.range(at: index)
            guard nsRange.location != NSNotFound else { return nil }
            let lower = string.utf16.index(string.utf16.startIndex, offsetBy: nsRange.location)
            let upper = string.utf16.index(lower, offsetBy: nsRange.length)
            return lower..<upper
        }
    }
}

extension StringProtocol where SubSequence == Substring {
    func matches(of r: IOS15Regex2) -> [IOS15Match2] {
        ios15Groups(self, r.regex, first: false).compactMap { g in
            guard g.count >= 3, let whole = g[0], let a = g[1], let b = g[2] else { return nil }
            return IOS15Match2(output: (self[whole], self[a], self[b]), range: whole)
        }
    }
    func firstMatch(of r: IOS15Regex2) -> IOS15Match2? {
        ios15Groups(self, r.regex, first: true).compactMap { g -> IOS15Match2? in
            guard g.count >= 3, let whole = g[0], let a = g[1], let b = g[2] else { return nil }
            return IOS15Match2(output: (self[whole], self[a], self[b]), range: whole)
        }.first
    }
    func matches(of r: IOS15Regex3) -> [IOS15Match3] {
        ios15Groups(self, r.regex, first: false).compactMap { g in
            guard g.count >= 4, let whole = g[0], let a = g[1], let b = g[2], let c = g[3] else { return nil }
            return IOS15Match3(output: (self[whole], self[a], self[b], self[c]), range: whole)
        }
    }
    func firstMatch(of r: IOS15Regex3) -> IOS15Match3? {
        ios15Groups(self, r.regex, first: true).compactMap { g -> IOS15Match3? in
            guard g.count >= 4, let whole = g[0], let a = g[1], let b = g[2], let c = g[3] else { return nil }
            return IOS15Match3(output: (self[whole], self[a], self[b], self[c]), range: whole)
        }.first
    }
    func matches(of r: IOS15Regex3Opt) -> [IOS15Match3Opt] {
        ios15Groups(self, r.regex, first: false).compactMap { g in
            guard g.count >= 4, let whole = g[0], let a = g[1], let b = g[2] else { return nil }
            return IOS15Match3Opt(output: (self[whole], self[a], self[b], g[3].map { self[$0] }), range: whole)
        }
    }
    func firstMatch(of r: IOS15Regex3Opt) -> IOS15Match3Opt? {
        ios15Groups(self, r.regex, first: true).compactMap { g -> IOS15Match3Opt? in
            guard g.count >= 4, let whole = g[0], let a = g[1], let b = g[2] else { return nil }
            return IOS15Match3Opt(output: (self[whole], self[a], self[b], g[3].map { self[$0] }), range: whole)
        }.first
    }
}
