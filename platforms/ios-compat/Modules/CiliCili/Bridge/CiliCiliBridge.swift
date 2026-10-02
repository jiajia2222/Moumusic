import SwiftUI
import UIKit

/// Moumusic 对 CiliCili 的入口：把 CiliCili 的主界面作为一个整体视图提供给宿主应用。
public struct CiliCiliHostView: View {
    @StateObject private var dependencies = AppDependencies()

    public init() {}

    public var body: some View {
        RootTabView()
            .scrollIndicators(.hidden, axes: .vertical)
            .environmentObject(dependencies)
            .environmentObject(dependencies.sessionStore)
            .environmentObject(dependencies.libraryStore)
            .environmentObject(dependencies.homeRecommendDiagnosticsStore)
    }
}

public enum CiliCiliBridge {
    /// 播放器全屏/横屏时 CiliCili 会修改它，宿主 AppDelegate 需要把它返回给系统。
    @MainActor
    public static var supportedOrientations: UIInterfaceOrientationMask {
        AppOrientationLock.supportedOrientations
    }
}
