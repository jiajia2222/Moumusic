# Third-party notices

Moumusic 是基于以下开源项目重构的独立仓库：

## Kumone（参考工程）

- Upstream: https://github.com/missuo/kumone
- Location: `platforms/ios`（保留 SwiftUI 参考源码；共享 RN 发布前端移植其导航、卡片与玻璃交互）
- License: LGPL-3.0-only
- 原项目的 `LICENSE` 与 `COPYING` 文件保留在 `platforms/ios`。

## LX Music Mobile（共享客户端基线）

- Upstream: https://github.com/lyswhut/lx-music-mobile
- Location: `platforms/android`
- License: Apache-2.0
- 原项目的 `LICENSE` 文件保留在 `platforms/android`。

Moumusic 的新增修改包括共享双端发布、Kumone 风格 RN 界面、LX 聚合搜索、平台/播放音源分层、iOS 原生桥接和发布配置；上游代码的版权和许可证继续适用。用户导入的音源脚本由用户自行提供，仓库不预置第三方音源脚本或服务地址。
