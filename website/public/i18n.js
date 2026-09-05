(() => {
  const messages = {
    zh: {
      'meta.homeTitle': 'Moumusic｜安装与支持',
      'meta.homeDescription': 'Moumusic 安装指南与项目支持页。三步添加音源，开始播放。',
      'meta.homeOgTitle': 'Moumusic｜先安装，再开始听歌',
      'meta.homeOgDescription': '查看 Moumusic 安装步骤，添加你有权使用的音源，并支持项目持续维护。',
      'meta.installTitle': '安装说明｜Moumusic',
      'meta.installDescription': 'Moumusic iOS 与 Android 安装说明。',
      'nav.install': '安装教程',
      'nav.sponsors': '支持者',
      'nav.support': '支持页',
      'nav.download': '下载',
      'language.switchToEnglish': '切换到 English',
      'language.switchToChinese': '切换到简体中文',
      'language.english': 'EN',
      'language.chinese': '中文',
      'theme.switchToDark': '切换到深色模式',
      'theme.switchToLight': '切换到浅色模式',
      'theme.dark': '深色',
      'theme.light': '浅色',
      'profile.home': 'Moumusic 首页',
      'profile.support': '返回 Moumusic 支持页',
      'profile.avatar': '头像',
      'hero.kicker': '先从这里开始',
      'hero.titleLead': '先安装，',
      'hero.titleEm': '再开始听歌。',
      'hero.tagline': '下载应用，添加你有权使用的音源，然后开始播放。整个流程只需要三步。',
      'hero.support': '支持 Moumusic',
      'hero.install': '看完整安装教程',
      'hero.meta': '最新版安装包 · iOS / Android',
      'hero.metaLink': '立即查看',
      'hero.installTip': '安装提示',
      'hero.cardTitle': '一个应用，<br><span>你自己的音源。</span>',
      'hero.cardBody': '音源由你在应用内添加和管理。我们不预置第三方链接。',
      'roadmap.title': '三步开始播放',
      'roadmap.caption': '先安装，再添加音源，最后开始听歌。',
      'roadmap.downloadTitle': '下载对应版本',
      'roadmap.downloadBody': 'iPhone / iPad 选择 IPA，Android 选择 APK，文件均来自项目 Release。',
      'roadmap.downloadLink': '选择你的设备',
      'roadmap.sourceTitle': '添加 LX 音源',
      'roadmap.sourceBody': '打开应用设置，导入你信任的 JSON、JS 或在线音源链接，再进行可用性检测。',
      'roadmap.sourceLink': '查看添加说明',
      'roadmap.playTitle': '开始播放',
      'roadmap.playBody': '搜索歌曲，选择音质。歌词、封面和播放地址会跟随当前可用音源解析。',
      'roadmap.playLink': '遇到问题？',
      'support.title': '如果 Moumusic 帮到了你，<br><span>欢迎支持下一次更新。</span>',
      'support.body': '每一份支持，都会回到维护、修复和新的播放体验里。',
      'support.button': '在爱发电赞助',
      'stats.label': '支持数据',
      'stats.supporters': '支持者',
      'stats.recent': '最近支持',
      'stats.total': '累计支持',
      'stats.ongoing': '持续支持中',
      'recent.title': '最近支持',
      'common.refresh': '刷新',
      'sponsors.title': '赞助者名单',
      'sponsors.description': '每一个名字，都是 Moumusic 继续向前的理由。',
      'sponsors.live': '持续更新',
      'sponsors.emptyTitle': '还没有赞助记录',
      'sponsors.emptyBody': '感谢每一位未来的支持者',
      'sponsors.errorTitle': '暂时无法获取赞助名单',
      'sponsors.errorBody': '稍后再试，顶部的爱发电入口仍然可以正常使用。',
      'sponsors.configErrorTitle': '赞助名单还未连接',
      'sponsors.configErrorBody': '管理员需要先配置爱发电 API，配置完成后点击“重新加载”即可查看。',
      'closing.thanks': '感谢每一位支持者，让 Moumusic 可以持续更新。',
      'footer.afdian': '前往爱发电',
      'footer.install': '安装说明',
      'footer.github': 'GitHub 源码',
      'dialog.close': '关闭',
      'dialog.supporter': '支持者',
      'dialog.plan': '持续支持中',
      'dialog.recent': '最近支持',
      'dialog.total': '累计支持',
      'dialog.thanks': '感谢你的支持',
      'supportDialog.close': '关闭',
      'supportDialog.kicker': 'SUPPORT MOUMUSIC',
      'supportDialog.title': '选择支持方案',
      'supportDialog.body': '付款由爱发电官方页面安全处理，方案和金额以官方页面显示为准。',
      'supportDialog.fallback': '如果内嵌页面被浏览器拦截：',
      'supportDialog.openDirect': '在新窗口打开爱发电',
      'chatway.fallbackButton': '在线反馈',
      'chatway.kicker': 'CHATWAY',
      'chatway.title': '联系支持',
      'chatway.issueLink': '也可以提交 GitHub Issue',
      'time.none': '暂无记录',
      'time.unavailable': '暂不可用',
      'time.justNow': '刚刚',
      'time.minutesAgo': '{count} 分钟前',
      'time.hoursAgo': '{count} 小时前',
      'time.daysAgo': '{count} 天前',
      'sponsor.supportedAt': '支持于 {date}',
      'install.kicker': 'GET STARTED',
      'install.title': '安装 Moumusic',
      'install.intro': '选择你的设备，几分钟内开始播放。iOS 与 Android 安装包均来自项目 Release。',
      'install.supportHero': '在爱发电支持我，让我能够上架到 TestFlight！',
      'install.releaseMeta': '下载入口始终指向 GitHub 最新 Release',
      'install.versionLoading': '正在获取最新版本…',
      'install.versionUnavailable': '最新版本信息暂不可用',
      'install.latestVersion': '最新版本 {version}',
      'install.releaseLink': '查看 Release ↗',
      'install.afterKicker': 'AFTER INSTALL',
      'install.sourceTitle': '安装完成后，添加你自己的音源',
      'install.sourceBody': '打开 Moumusic 的“我的 → 设置 → LX 音源”，可以导入 JSON、JavaScript 文件或在线链接，然后点击检测并启用可用音源。',
      'install.methods': '安装方式',
      'install.iosTitle': 'iOS 安装',
      'install.iosLead': '下载未签名 IPA，再用自己的签名方式安装。',
      'install.iosStep1': '下载最新的 <strong>iOS IPA</strong>。',
      'install.iosStep2': '使用 AltStore、SideStore、Feather、Sideloadly 或你信任的签名工具导入。',
      'install.iosStep3': '完成签名后安装；首次使用按系统提示信任对应开发者。',
      'install.iosDownload': '下载 iOS IPA',
      'install.iosNote': 'IPA 未签名，无法直接通过系统安装。',
      'install.sideloadly': '使用 Sideloadly 自签：',
      'install.windows': 'Windows 版 ↗',
      'install.macos': 'macOS 版 ↗',
      'install.androidTitle': 'Android 安装',
      'install.androidLead': '下载 APK 后按系统提示完成安装。',
      'install.androidStep1': '下载最新的 <strong>Android APK</strong>。',
      'install.androidStep2': '打开 APK；若系统提示，允许浏览器或文件管理器安装未知来源应用。',
      'install.androidStep3': '安装完成后打开 Moumusic，并在应用内导入你有权使用的音源。',
      'install.androidDownload': '下载 Android APK',
      'install.androidNote': '建议从本项目 GitHub Release 下载，核对文件名和版本号。',
      'install.troubleKicker': 'TROUBLESHOOTING',
      'install.troubleTitle': '安装后遇到问题？',
      'install.troubleIos': '<strong>iOS 无法打开：</strong>确认 IPA 已使用你自己的证书签名，并检查证书是否有效。',
      'install.troublePlay': '<strong>播放没有声音：</strong>先在应用内添加并测试可用的 LX 音源。',
      'install.troubleList': '<strong>页面或名单加载失败：</strong>稍后刷新；爱发电支持入口不会受名单 API 影响。',
      'install.footerHelp': '需要帮助？先回到',
      'install.footerSupport': '支持页',
    },
    en: {
      'meta.homeTitle': 'Moumusic | Install and support',
      'meta.homeDescription': 'Moumusic installation guide and project support page. Add a source and start playing in three steps.',
      'meta.homeOgTitle': 'Moumusic | Install first, then press play',
      'meta.homeOgDescription': 'Follow the Moumusic setup guide, add a source you are allowed to use, and support continued maintenance.',
      'meta.installTitle': 'Install guide | Moumusic',
      'meta.installDescription': 'Installation guide for Moumusic on iOS and Android.',
      'nav.install': 'Install guide',
      'nav.sponsors': 'Supporters',
      'nav.support': 'Support',
      'nav.download': 'Downloads',
      'language.switchToEnglish': 'Switch to English',
      'language.switchToChinese': '切换到简体中文',
      'language.english': 'EN',
      'language.chinese': '中文',
      'theme.switchToDark': 'Switch to dark mode',
      'theme.switchToLight': 'Switch to light mode',
      'theme.dark': 'Dark',
      'theme.light': 'Light',
      'profile.home': 'Moumusic home',
      'profile.support': 'Back to Moumusic support',
      'profile.avatar': 'Avatar',
      'hero.kicker': 'START HERE',
      'hero.titleLead': 'Install first, ',
      'hero.titleEm': 'then press play.',
      'hero.tagline': 'Download the app, add a source you are allowed to use, and start playing. It only takes three steps.',
      'hero.support': 'Support Moumusic',
      'hero.install': 'View the install guide',
      'hero.meta': 'Latest builds · iOS / Android',
      'hero.metaLink': 'View downloads',
      'hero.installTip': 'INSTALL NOTE',
      'hero.cardTitle': 'One app,<br><span>your own sources.</span>',
      'hero.cardBody': 'Add and manage sources inside the app. No third-party links are bundled.',
      'roadmap.title': 'Three steps to play',
      'roadmap.caption': 'Install, add a source, then start listening.',
      'roadmap.downloadTitle': 'Download your build',
      'roadmap.downloadBody': 'Choose IPA for iPhone / iPad and APK for Android. Files come from the project Release.',
      'roadmap.downloadLink': 'Choose your device',
      'roadmap.sourceTitle': 'Add an LX source',
      'roadmap.sourceBody': 'Open app settings, import a trusted JSON, JS, or online source URL, then run the availability check.',
      'roadmap.sourceLink': 'View source instructions',
      'roadmap.playTitle': 'Start playing',
      'roadmap.playBody': 'Search for a song and choose a quality. Lyrics, artwork, and playback URLs follow the active source.',
      'roadmap.playLink': 'Need help?',
      'support.title': 'If Moumusic has helped you,<br><span>support the next update.</span>',
      'support.body': 'Every contribution goes back into maintenance, fixes, and a better listening experience.',
      'support.button': 'Support on Afdian',
      'stats.label': 'SUPPORT DATA',
      'stats.supporters': 'Supporters',
      'stats.recent': 'Recent support',
      'stats.total': 'Total support',
      'stats.ongoing': 'Ongoing support',
      'recent.title': 'Recent support',
      'common.refresh': 'Refresh',
      'sponsors.title': 'Supporter wall',
      'sponsors.description': 'Every name is a reason for Moumusic to keep moving forward.',
      'sponsors.live': 'Updated regularly',
      'sponsors.emptyTitle': 'No support records yet',
      'sponsors.emptyBody': 'Thank you to everyone who may support in the future',
      'sponsors.errorTitle': 'Supporters are temporarily unavailable',
      'sponsors.errorBody': 'Please try again later. The Afdian entry above remains available.',
      'sponsors.configErrorTitle': 'Supporter list is not connected',
      'sponsors.configErrorBody': 'The site administrator needs to configure the Afdian API first, then reload this page.',
      'closing.thanks': 'Thank you to every supporter for helping Moumusic keep moving.',
      'footer.afdian': 'Open Afdian',
      'footer.install': 'Install guide',
      'footer.github': 'GitHub source',
      'dialog.close': 'Close',
      'dialog.supporter': 'Supporter',
      'dialog.plan': 'Ongoing support',
      'dialog.recent': 'Recent support',
      'dialog.total': 'Total support',
      'dialog.thanks': 'Thank you for your support',
      'supportDialog.close': 'Close',
      'supportDialog.kicker': 'SUPPORT MOUMUSIC',
      'supportDialog.title': 'Choose a support plan',
      'supportDialog.body': 'Payment is handled securely by the official Afdian page. Plans and amounts follow the official page.',
      'supportDialog.fallback': 'If your browser blocks the embedded page:',
      'supportDialog.openDirect': 'Open Afdian in a new window',
      'chatway.fallbackButton': 'Contact support',
      'chatway.kicker': 'CHATWAY',
      'chatway.title': 'Contact support',
      'chatway.issueLink': 'You can also submit a GitHub Issue',
      'time.none': 'No record',
      'time.unavailable': 'Unavailable',
      'time.justNow': 'Just now',
      'time.minutesAgo': '{count} min ago',
      'time.hoursAgo': '{count} hr ago',
      'time.daysAgo': '{count} days ago',
      'sponsor.supportedAt': 'Supported {date}',
      'install.kicker': 'GET STARTED',
      'install.title': 'Install Moumusic',
      'install.intro': 'Choose your device and start playing in minutes. iOS and Android packages come from the project Release.',
      'install.supportHero': 'Support me on Afdian so I can bring Moumusic to TestFlight!',
      'install.releaseMeta': 'Download links always point to the latest GitHub Release',
      'install.versionLoading': 'Fetching the latest version…',
      'install.versionUnavailable': 'Latest version unavailable',
      'install.latestVersion': 'Latest version {version}',
      'install.releaseLink': 'View Release ↗',
      'install.afterKicker': 'AFTER INSTALL',
      'install.sourceTitle': 'After installing, add your own source',
      'install.sourceBody': 'Open “Me → Settings → LX Sources” in Moumusic, import a JSON or JavaScript file or an online URL, then check and enable an available source.',
      'install.methods': 'INSTALL METHODS',
      'install.iosTitle': 'Install on iOS',
      'install.iosLead': 'Download the unsigned IPA, then install it with your own signing method.',
      'install.iosStep1': 'Download the latest <strong>iOS IPA</strong>.',
      'install.iosStep2': 'Import it with AltStore, SideStore, Feather, Sideloadly, or another trusted signing tool.',
      'install.iosStep3': 'Install after signing; trust the developer in Settings if iOS asks you to.',
      'install.iosDownload': 'Download iOS IPA',
      'install.iosNote': 'The IPA is unsigned and cannot be installed directly by iOS.',
      'install.sideloadly': 'Self-sign with Sideloadly:',
      'install.windows': 'Windows ↗',
      'install.macos': 'macOS ↗',
      'install.androidTitle': 'Install on Android',
      'install.androidLead': 'Download the APK and follow the system prompts.',
      'install.androidStep1': 'Download the latest <strong>Android APK</strong>.',
      'install.androidStep2': 'Open the APK; if asked, allow your browser or file manager to install unknown apps.',
      'install.androidStep3': 'Open Moumusic after installation and import a source you are allowed to use.',
      'install.androidDownload': 'Download Android APK',
      'install.androidNote': 'Download from this project’s GitHub Release and check the filename and version.',
      'install.troubleKicker': 'TROUBLESHOOTING',
      'install.troubleTitle': 'Something wrong after installing?',
      'install.troubleIos': '<strong>iOS will not open:</strong> confirm that the IPA was signed with your own valid certificate.',
      'install.troublePlay': '<strong>No sound:</strong> add and test an available LX source in the app first.',
      'install.troubleList': '<strong>Page or list failed to load:</strong> refresh later; the Afdian support entry is independent of the sponsor API.',
      'install.footerHelp': 'Need help? Return to',
      'install.footerSupport': 'the support page',
    },
  }

  const storageKey = 'moumusic-language'
  const themeStorageKey = 'moumusic-theme'
  let language = 'zh'
  let theme = 'system'
  try {
    const stored = window.localStorage.getItem(storageKey)
    if (stored === 'en' || stored === 'zh') language = stored
    else if (navigator.language && !navigator.language.toLowerCase().startsWith('zh')) language = 'en'
  } catch {
    // Use Chinese when storage is unavailable.
  }

  try {
    const storedTheme = window.localStorage.getItem(themeStorageKey)
    if (storedTheme === 'light' || storedTheme === 'dark' || storedTheme === 'system') theme = storedTheme
  } catch {
    // Use the system theme when storage is unavailable.
  }

  function systemIsDark() {
    return window.matchMedia?.('(prefers-color-scheme: dark)').matches === true
  }

  function applyTheme() {
    const root = document.documentElement
    if (theme === 'system') root.removeAttribute('data-theme')
    else root.dataset.theme = theme

    const toggle = document.getElementById('theme-toggle')
    if (!toggle) return
    const isDark = theme === 'dark' || (theme === 'system' && systemIsDark())
    const nextKey = isDark ? 'theme.light' : 'theme.dark'
    const labelKey = isDark ? 'theme.switchToLight' : 'theme.switchToDark'
    const label = document.getElementById('theme-toggle-label')
    if (label) label.textContent = translate(nextKey)
    toggle.setAttribute('aria-label', translate(labelKey))
    toggle.title = translate(labelKey)
    toggle.dataset.appearance = isDark ? 'dark' : 'light'
  }

  function translate(key, variables = {}) {
    const value = messages[language]?.[key] ?? messages.zh[key] ?? key
    return Object.entries(variables).reduce(
      (result, [name, replacement]) => result.replaceAll(`{${name}}`, String(replacement)),
      value,
    )
  }

  function apply(root = document) {
    document.documentElement.lang = language === 'en' ? 'en' : 'zh-CN'
    root.querySelectorAll('[data-i18n]').forEach(element => {
      const value = translate(element.dataset.i18n)
      if (element.dataset.i18nHtml === 'true') element.innerHTML = value
      else element.textContent = value
    })
    root.querySelectorAll('[data-i18n-content]').forEach(element => {
      element.setAttribute('content', translate(element.dataset.i18nContent))
    })
    root.querySelectorAll('[data-i18n-aria-label]').forEach(element => {
      element.setAttribute('aria-label', translate(element.dataset.i18nAriaLabel))
    })
    const toggle = document.getElementById('language-toggle')
    if (toggle) {
      toggle.textContent = translate(language === 'en' ? 'language.chinese' : 'language.english')
      toggle.setAttribute('aria-label', translate(language === 'en' ? 'language.switchToChinese' : 'language.switchToEnglish'))
      toggle.title = toggle.getAttribute('aria-label')
    }
    applyTheme()
  }

  function setTheme(nextTheme) {
    if (!['light', 'dark', 'system'].includes(nextTheme)) return
    theme = nextTheme
    try { window.localStorage.setItem(themeStorageKey, theme) } catch { /* Ignore private mode storage errors. */ }
    applyTheme()
  }

  function setLanguage(nextLanguage) {
    if (nextLanguage !== 'en' && nextLanguage !== 'zh') return
    language = nextLanguage
    try { window.localStorage.setItem(storageKey, language) } catch { /* Ignore private mode storage errors. */ }
    apply()
    document.dispatchEvent(new CustomEvent('moumusic:languagechange', { detail: { language } }))
  }

  window.MoumusicI18n = { apply, language: () => language, setLanguage, setTheme, t: translate }
  apply()
  document.addEventListener('click', event => {
    const toggle = event.target.closest('#language-toggle')
    if (toggle) setLanguage(language === 'en' ? 'zh' : 'en')
    const themeToggle = event.target.closest('#theme-toggle')
    if (themeToggle) {
      const isDark = theme === 'dark' || (theme === 'system' && systemIsDark())
      setTheme(isDark ? 'light' : 'dark')
    }
  })
  window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener?.('change', () => {
    if (theme === 'system') applyTheme()
  })
})()
