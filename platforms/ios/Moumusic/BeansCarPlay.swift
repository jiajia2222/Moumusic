import CarPlay
import UIKit

extension PlayerManager {
    /// CarPlay 与主界面共用同一个播放器实例（CarPlay 单独启动时主窗口可能还没创建）。
    static let shared = PlayerManager()
}

/// CarPlay 场景：推荐榜单、最近播放、本地歌单，点歌后进入「正在播放」。
/// 需要带 CarPlay 音频权限（com.apple.developer.carplay-audio）的签名才能在车机上显示。
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        Task { @MainActor in
            BeansCarPlayCoordinator.shared.connect(interfaceController)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in
            BeansCarPlayCoordinator.shared.disconnect()
        }
    }
}

@MainActor
final class BeansCarPlayCoordinator {
    static let shared = BeansCarPlayCoordinator()

    private var controller: CPInterfaceController?
    private var player: PlayerManager { PlayerManager.shared }

    func connect(_ controller: CPInterfaceController) {
        self.controller = controller
        BeansLogger.shared.log("CarPlay 已连接", level: .info)
        let tabs = CPTabBarTemplate(templates: [recommendTemplate(), historyTemplate(), localTemplate()])
        controller.setRootTemplate(tabs, animated: false, completion: nil)
    }

    func disconnect() {
        controller = nil
        BeansLogger.shared.log("CarPlay 已断开", level: .info)
    }

    // MARK: 推荐（网易云榜单）

    private func recommendTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "推荐", sections: [CPListSection(items: [])])
        template.tabTitle = "推荐"
        template.tabImage = UIImage(systemName: "sparkles")
        template.emptyViewSubtitleVariants = ["正在加载…"]
        Task { [weak self, weak template] in
            guard let self = self, let template = template else { return }
            let lists = (try? await NetEaseAPI.shared.topLists()) ?? []
            let items = lists.prefix(12).map { top -> CPListItem in
                let item = CPListItem(text: top.name, detailText: nil)
                item.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        await self?.pushSongs(title: top.name) { try await NetEaseAPI.shared.playlistTracks(id: top.id) }
                        completion()
                    }
                }
                return item
            }
            template.updateSections([CPListSection(items: items)])
            if items.isEmpty { template.emptyViewSubtitleVariants = ["暂无推荐内容"] }
        }
        return template
    }

    // MARK: 最近播放

    private func historyTemplate() -> CPListTemplate {
        let songs = Array(player.history.prefix(30))
        let template = CPListTemplate(title: "最近播放", sections: [CPListSection(items: songItems(songs))])
        template.tabTitle = "最近播放"
        template.tabImage = UIImage(systemName: "clock")
        template.emptyViewSubtitleVariants = ["暂无本地播放记录"]
        return template
    }

    // MARK: 本地歌单

    private func localTemplate() -> CPListTemplate {
        let items = LocalLibraryStore.shared.playlists.map { playlist -> CPListItem in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.songs.count) 首")
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.pushSongs(title: playlist.name) { playlist.songs }
                    completion()
                }
            }
            return item
        }
        let template = CPListTemplate(title: "我的歌单", sections: [CPListSection(items: items)])
        template.tabTitle = "我的歌单"
        template.tabImage = UIImage(systemName: "music.note.list")
        template.emptyViewSubtitleVariants = ["还没有本地歌单"]
        return template
    }

    // MARK: 歌曲列表

    private func pushSongs(title: String, loader: @escaping () async throws -> [Song]) async {
        guard let controller = controller else { return }
        let songs = ((try? await loader()) ?? []).prefix(60).map { $0 }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: songItems(songs))])
        template.emptyViewSubtitleVariants = ["歌单暂无歌曲"]
        controller.pushTemplate(template, animated: true, completion: nil)
    }

    private func songItems(_ songs: [Song]) -> [CPListItem] {
        songs.enumerated().map { index, song in
            let item = CPListItem(text: song.name, detailText: song.artists)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.player.play(songs: songs, startAt: index)
                    if let controller = self?.controller {
                        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                    }
                    completion()
                }
            }
            return item
        }
    }
}
