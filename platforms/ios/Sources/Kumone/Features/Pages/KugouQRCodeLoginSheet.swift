#if os(iOS)
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct KugouQRCodeLoginSheet: View {
    private enum Phase: Equatable {
        case loading, waiting, scanned, expired, failed(String)
    }

    @EnvironmentObject private var kugou: KugouSessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var key: String?
    @State private var sessionCookie = ""
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Label("酷狗音乐扫码登录", systemImage: "qrcode.viewfinder")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 12)

                    Text("使用酷狗音乐 App 扫码确认。登录凭据只保存在本机钥匙串，账号音源仍按播放设置决定。")
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
            .navigationTitle("酷狗音乐登录")
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
        .accessibilityLabel("酷狗音乐扫码登录二维码")
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading: Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting: Label("打开酷狗音乐 App 扫一扫", systemImage: "qrcode.viewfinder")
        case .scanned: Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .expired: Label("二维码已过期", systemImage: "clock.badge.exclamationmark").foregroundStyle(Theme.accent)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func startLogin(reusingKey: Bool = false) {
        pollTask?.cancel()
        phase = .loading
        pollTask = Task { @MainActor in
            do {
                let activeKey: String
                let activeCookie: String
                if reusingKey, let key, !sessionCookie.isEmpty {
                    activeKey = key
                    activeCookie = sessionCookie
                    phase = .waiting
                } else {
                    let payload = try await KugouAPI.shared.qrCode()
                    activeKey = payload.key
                    activeCookie = payload.cookie
                    key = payload.key
                    sessionCookie = payload.cookie
                    qrImage = Self.makeQRImage(from: payload.url)
                    phase = .waiting
                }

                var errors = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2.5))
                    do {
                        switch try await KugouAPI.shared.poll(qrcode: activeKey, cookie: activeCookie) {
                        case .waiting: phase = .waiting
                        case .scanned: phase = .scanned
                        case .expired:
                            phase = .expired
                            key = nil
                            sessionCookie = ""
                            pollTask = nil
                            return
                        case .success(let cookie):
                            try await kugou.signIn(cookie: cookie)
                            ToastCenter.shared.show("酷狗音乐账号登录成功")
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
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
