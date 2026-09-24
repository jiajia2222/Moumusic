#if os(iOS)
import CoreImage.CIFilterBuiltins
import SwiftUI

struct BilibiliLoginSheet: View {
    private enum Phase: Equatable {
        case loading, waiting, scanned, expired, failed(String)
    }

    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var key: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Label("哔哩哔哩扫码同步", systemImage: "play.rectangle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 12)

                    Text("使用哔哩哔哩 App 扫码。这里只同步账号资料和公开信息，不会读取密码，也不会把 B 站账号当作音源。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)

                    qrCard
                    statusView

                    if phase == .expired || isFailed {
                        Button("重新获取二维码") { startLogin() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .navigationTitle("哔哩哔哩登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { startLogin() }
            .onDisappear { pollTask?.cancel() }
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active, key != nil else { return }
                startLogin(reusingKey: true)
            }
        }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .frame(width: 272, height: 272)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 232, height: 232)
                    .opacity(phase == .expired ? 0.25 : 1)
            } else {
                ProgressView()
            }
            if phase == .expired || phase == .scanned {
                VStack(spacing: 8) {
                    Image(systemName: phase == .expired ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(phase == .expired ? Theme.accent : .green)
                    Text(phase == .expired ? "二维码已失效" : "已扫码，请在手机确认")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("哔哩哔哩扫码登录二维码")
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading: Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting: Label("打开哔哩哔哩 App 扫一扫", systemImage: "qrcode.viewfinder")
        case .scanned: Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .expired: Label("二维码已过期", systemImage: "clock.badge.exclamationmark").foregroundStyle(Theme.accent)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
        }
    }

    private func startLogin(reusingKey: Bool = false) {
        pollTask?.cancel()
        phase = .loading
        pollTask = Task { @MainActor in
            do {
                let activeKey: String
                if reusingKey, let key {
                    activeKey = key
                    phase = .waiting
                } else {
                    let payload = try await BilibiliAPI.shared.qrCode()
                    activeKey = payload.key
                    key = payload.key
                    qrImage = Self.makeQRImage(from: payload.url)
                    phase = .waiting
                }

                var errors = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2.5))
                    do {
                        switch try await BilibiliAPI.shared.poll(key: activeKey) {
                        case .waiting: phase = .waiting
                        case .scanned: phase = .scanned
                        case .expired: phase = .expired; pollTask = nil; return
                        case .success(let cookie):
                            try await bilibili.signIn(cookie: cookie)
                            ToastCenter.shared.show("哔哩哔哩账号同步成功")
                            pollTask = nil
                            dismiss()
                            return
                        }
                        errors = 0
                    } catch {
                        errors += 1
                        if errors >= 8 { throw error }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    pollTask = nil
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static func makeQRImage(from value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
