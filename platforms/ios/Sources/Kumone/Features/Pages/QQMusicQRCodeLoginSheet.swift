#if os(iOS)
import SwiftUI
import UIKit

struct QQMusicQRCodeLoginSheet: View {
    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case expired
        case failed(String)
    }

    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var qrsig: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("使用 QQ 音乐 App 扫码登录")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 16)

                Text("登录只用于同步 QQ 音乐账号资料与歌单。Cookie 仅保存在本机钥匙串，不会显示给网页或上传服务器。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                qrCard
                statusView

                if phase == .expired || isFailed {
                    Button("重新获取二维码") { startLogin() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 12)
            .navigationTitle("QQ 音乐扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { startLogin() }
            .onDisappear { pollTask?.cancel() }
            .onChange(of: scenePhase) { newPhase in
                guard newPhase == .active, qrsig != nil else { return }
                startLogin(reusingCode: true)
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
            } else if isFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.accent)
                    Text("二维码暂时不可用")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            if phase == .expired || phase == .scanned {
                VStack(spacing: 8) {
                    Image(systemName: phase == .expired ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(phase == .expired ? Theme.accent : .green)
                    Text(phase == .expired ? "二维码已失效" : "已扫码，请在手机上确认")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("QQ 音乐扫码登录二维码")
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading: Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting: Label("打开 QQ 音乐 App 扫一扫", systemImage: "qrcode.viewfinder")
        case .scanned: Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .expired: Label("二维码已过期", systemImage: "clock.badge.exclamationmark").foregroundStyle(Theme.accent)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
        }
    }

    private func startLogin(reusingCode: Bool = false) {
        pollTask?.cancel()
        phase = .loading
        if !reusingCode {
            qrImage = nil
            qrsig = nil
        }
        pollTask = Task { @MainActor in
            do {
                let activeQRSig: String
                if reusingCode, let qrsig {
                    activeQRSig = qrsig
                    phase = .waiting
                } else {
                    let payload = try await requestQRCodeWithRetry()
                    activeQRSig = payload.qrsig
                    qrsig = payload.qrsig
                    guard let image = UIImage(data: payload.imageData) else {
                        throw QQMusicAPI.APIError.qrCodeUnavailable
                    }
                    qrImage = image
                    phase = .waiting
                }

                var errors = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2.5))
                    do {
                        switch try await QQMusicAPI.shared.poll(qrsig: activeQRSig) {
                        case .waiting: phase = .waiting
                        case .scanned: phase = .scanned
                        case .expired: phase = .expired; pollTask = nil; return
                        case .success(let cookie):
                            try await qqMusic.signIn(cookie: cookie)
                            ToastCenter.shared.show("QQ 音乐账号同步成功")
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

    private func requestQRCodeWithRetry() async throws -> QQMusicAPI.QRCodePayload {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await QQMusicAPI.shared.qrCode()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(for: .milliseconds(700))
                }
            }
        }
        throw lastError ?? QQMusicAPI.APIError.qrCodeUnavailable
    }
}
#endif
