#if os(iOS)
import SwiftUI

/// Owns the one-time "What's New" presentation marker. The marker contains
/// both marketing and build versions so an in-place update shows the log once,
/// while relaunching the same installed build does not interrupt playback.
@MainActor
final class IOSUpdateLogStore: ObservableObject {
    static let shared = IOSUpdateLogStore()

    @Published var isPresented = false
    @Published private(set) var version = ReleaseChecker.currentDisplayVersion

    private let lastPresentedKey = "ios.updateLog.lastPresentedIdentity"

    func presentIfNeeded() {
        let identity = ReleaseChecker.currentIdentity
        guard identity.isValid else { return }
        let marker = "\(identity.shortVersion)#\(identity.buildNumber)"
        guard UserDefaults.standard.string(forKey: lastPresentedKey) != marker else { return }
        UserDefaults.standard.set(marker, forKey: lastPresentedKey)
        version = identity.displayVersion
        isPresented = true
    }

    func present() {
        version = ReleaseChecker.currentDisplayVersion
        isPresented = true
    }
}

struct IOSUpdateLogSheet: View {
    @StateObject private var updateLog = IOSUpdateLogStore.shared
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String, String)] = [
        ("waveform", "音质更真实", "音质以音频文件实测为准（FLAC 位深 / 采样率 / 声道、MP3 码率），同一首歌的音质列表不再忽有忽无；没拿到所选音质时先重试再降级，并新增「音质降级时提示」开关，每首歌的音质详情写入诊断日志。"),
        ("music.note.list", "平台音质", "QQ 音乐、酷狗按每首歌的真实音质表显示可选档位，各平台用自己的音质名称（臻品 / 蝰蛇 / PQ·HQ·SQ·ZQ）；新增酷我、咪咕官方路线（无需登录）；本平台没有所选音质时才去其他平台找，播放失败也会换平台。"),
        ("square.grid.2x2", "首页与发现", "首页只显示各平台官方排行榜（咪咕暂无榜单，显示热门歌单），公告可点 X 关闭；发现页保留官方推荐歌单，下拉刷新不再失败、不再整页下移，每次刷新会换一批歌曲，不再闪回旧列表；进歌单再返回，发现页不再跳回首页选的平台；QQ 音乐部分歌单无法打开已修复；酷我封面修复。"),
        ("bolt.fill", "播放更快", "自动模式有音源时优先走第三方，不再先探测官方账号；备用音源只在主音源完全失败时才用，起播更快；试听片段改为起播后再检测；切换音质立即从原位置继续播放。"),
        ("play.rectangle", "哔哩哔哩", "「听视频」改走 HLS，加载更快；弹幕按 120Hz 更流畅；横屏全屏更稳；新增默认字幕、默认倍速与控件背景设置；点 UP 主名进入主页并可关注；相关视频直接替换当前页；搜索支持模糊匹配、UP 主合集与下拉刷新；评论区支持给评论点赞、回复评论（含楼中楼）。"),
        ("timer", "细节修复", "睡眠定时显示分钟与倒计时，到点同时停止哔哩哔哩播放；锁屏沉浸封面开关即时生效；歌词同步修复；首页标题不再重复；唱片播放器新增完整歌词页（点唱片或下方歌词进入，点左上小唱片返回）；音量条与两侧图标对齐；酷狗账号设备注册修复（歌单同步请用「扫码登录」，网页登录的令牌酷狗歌单接口不认）；酷狗扫码登录失败时会显示原因。推荐页不再显示酷狗「我的歌单」（歌单在账号页）。竖屏视频全屏时跟随手机方向，手机横着时不再出现画面倒向一侧；当前歌词行末尾被裁掉（穿模）修复，长句只换行不再放大；歌词时间微调（比原来提前约 0.1 秒）；评论页最后一条评论不再被发表评论栏挡住；音量条始终与两侧图标对齐；登录后各平台首页都有「每日推荐」（网易云按账号口味，QQ 音乐、酷狗用你账号的个性化推荐，其他平台每天换一批）；修复逐字歌词行首行尾空格造成的重影；歌词设置新增「这首歌的歌词同步」，每首歌单独调整并自动记住；接入社区校对的逐字歌词库（AMLL TTML DB），库里有的歌曲歌词按真实录音人工校对，更准；社区歌词库改为后台预加载，不再拖慢歌词加载；歌词样式「AMLL」改为官方原版播放器（弹簧滚动、逐字高亮、背景人声与对唱），删除原来的仿制样式。AMLL 歌词字体更大、整行铺满再换行，并解除网页 60 帧限制，支持高刷新率；切歌时歌词不再闪烁、不再卡顿；AMLL 的翻译随当前行高亮，字重与普通歌词一致；点歌词快进后，歌词行上的背景框不再残留；歌曲重播、重置时 AMLL 歌词不再留空；AMLL 歌词不再自带提前量，修复歌词整体偏早；社区校对歌词库新增按歌名和歌手匹配（含 Apple Music、Spotify 收录），其他平台的歌也能用上人工校对的逐字歌词；歌词和实际音频不是同一版本（歌词比音频还长）时自动换其他来源的歌词；逐字歌词改为 LDDC 的方式：同时查 QQ、酷狗、网易云，多个平台首句和末句时间都一致的优先（避免开头准、后半段整体错位），再取与音频时长最吻合的一份（有的歌有时对有时不对，就是各平台版本不同）；其次才用社区校对歌词库（AMLL TTML DB）；歌词设置里显示当前输出设备和自动补偿的秒数，方便校准。Hi-Res/FLAC 高音质播放时歌词越往后越偏的问题修复（FLAC 改用精确计时，起播要先读文件，母带约晚 8 秒、其他 1 到 2 秒，换来歌词准确）；换源重试时不再用只有一两行的残缺歌词替换完整歌词（纯音乐不受影响）；导入备份改用与导入音源相同的文件选择方式，修复点了没反应；诊断日志新增「播放时钟」监测（拖动进度条不再误报；定位完成后记录落点和耗时；时钟与实际时间不符、位置意外跳变、缓冲等待都会记录），用来查歌词越播越偏；拖动进度条后歌词跟不上的问题修复（拖动期间歌词直接跟随目标位置；网络流的定位允许 0.5 秒误差，不再等精确定位卡住）；歌词查找顺序调整：先找歌曲所在平台自己的歌词（有逐字歌词就直接用，更快），没有再比对其他平台；歌词翻译错位修复（每句翻译只给离它最近的一行，开头的作词、作曲不再带上第一句歌词的翻译）；FLAC 歌词精确同步改回默认关闭（开启后在部分网络下会卡住），按实验功能保留；B 站动态页偶尔封面突然变得很大的问题修复；修复歌曲开头歌词被连换两次导致的闪烁和错位（逐字歌词开启时不再重复改用其他平台的歌词）；歌词翻译按歌词文字匹配，不再把同一句翻译挂在作词、作曲等行下面；部分歌曲歌词只有两行的问题修复（音频取自其他平台时，「歌词改用该平台版本」会拿只有作词作曲的残缺歌词顶掉完整的逐字歌词，现已拦住），这类残缺歌词会跳过、换其他来源（诊断日志会记录每个来源的行数和被跳过的残缺歌词）；歌词不再等最慢的平台（拿到第一份后最多再等 1.2 秒）；歌词设置新增「高音质（FLAC）歌词精确同步」开关，默认开启：Hi-Res / FLAC 要先读一遍文件才能准确定位，起播会慢 1 到 8 秒，换来快进、点歌词和歌词对齐正常；嫌慢可以在歌词设置里关闭；账号页移除重复的「听歌时长」卡片（网易云的账号同步页里有同样的听歌同步）；经典播放页移除左上角圆形收起按钮（不再与歌名重叠，下滑即可收起）。"),
        ("iphone", "iOS 15–18 兼容版", "修复点进歌单、专辑等详情页空白的问题。"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHAT'S NEW")
                            .font(.caption.weight(.bold))
                            .tracking(1.8)
                            .foregroundStyle(Theme.accent)
                        Text("更新日志")
                            .font(.largeTitle.weight(.bold))
                        Text("Moumusic \(updateLog.version)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.0)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(LocalizedStringKey(item.1)).font(.headline)
                                    Text(LocalizedStringKey(item.2))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 15)
                            if index < items.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .mouMaterialBackground(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(20)
            }
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
