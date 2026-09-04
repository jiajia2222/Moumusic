const tracks = [
  { id: 'jay-clock', title: '反方向的钟', artist: '周杰伦', album: '十一月的萧邦', platform: 'netease', source: '网易云', quality: '无损 FLAC', duration: 222, cover: 'cover-amber', lyric: '演示歌词入口已就绪。接入音源后，会根据歌曲 ID 匹配歌词并同步播放进度。' },
  { id: 'jay-sunny', title: '晴天', artist: '周杰伦', album: '叶惠美', platform: 'qq', source: 'QQ 音乐', quality: '高品质 AAC', duration: 269, cover: 'cover-blue', lyric: '歌曲详情、歌词与音质会跟随当前可用音源展示。' },
  { id: 'jay-rice', title: '稻香', artist: '周杰伦', album: '魔杰座', platform: 'kuwo', source: '酷我', quality: '无损 FLAC', duration: 223, cover: 'cover-green', lyric: '不同平台可以聚合搜索，也可以单独查看来源。' },
  { id: 'pretty-rock', title: 'Pretty Girl Rock', artist: 'Keri Hilson', album: 'No Boys Allowed', platform: 'kugou', source: '酷狗', quality: '标准 MP3', duration: 243, cover: 'cover-plum', lyric: 'English lyrics are ready for synchronized display in the player.' },
]

const state = {
  view: 'home',
  platform: 'all',
  query: '',
  current: tracks[0],
  playing: false,
  progress: 0,
  playlist: [...tracks],
  toastTimer: null,
}

const $ = selector => document.querySelector(selector)
const $$ = selector => [...document.querySelectorAll(selector)]

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[character])
}

function formatTime(seconds) {
  const safeSeconds = Math.max(0, Math.floor(seconds || 0))
  return `${String(Math.floor(safeSeconds / 60)).padStart(2, '0')}:${String(safeSeconds % 60).padStart(2, '0')}`
}

function filteredTracks() {
  const query = state.query.trim().toLowerCase()
  return tracks.filter(track => {
    const matchesPlatform = state.platform === 'all' || track.platform === state.platform
    const matchesQuery = !query || [track.title, track.artist, track.album, track.source].some(value => value.toLowerCase().includes(query))
    return matchesPlatform && matchesQuery
  })
}

function trackMarkup(track, index = 0, compact = false) {
  const saved = state.playlist.some(item => item.id === track.id)
  return `<article class="track-row" data-track-id="${escapeHtml(track.id)}" tabindex="0" aria-label="查看 ${escapeHtml(track.title)} 详情">
    <span class="track-number">${String(index + 1).padStart(2, '0')}</span>
    <span class="track-thumb ${track.cover}">${track.title.slice(0, 1)}</span>
    <span class="track-main"><strong>${escapeHtml(track.title)}</strong><span>${escapeHtml(track.artist)} · ${escapeHtml(track.album)}</span></span>
    ${compact ? '' : `<span class="source-pill">${escapeHtml(track.source)}</span>`}
    <span class="quality-pill">${escapeHtml(track.quality)}</span>
    <span class="row-actions"><button class="row-action" data-play-track="${escapeHtml(track.id)}" type="button" aria-label="播放 ${escapeHtml(track.title)}">▶</button><button class="row-action" data-add-track="${escapeHtml(track.id)}" type="button" aria-label="${saved ? '移出' : '加入'}歌单">${saved ? '✓' : '+'}</button></span>
  </article>`
}

function renderHome() {
  $('#homeTrackList').innerHTML = tracks.map((track, index) => trackMarkup(track, index)).join('')
}

function renderSearch() {
  const results = filteredTracks()
  const queryLabel = state.query ? `“${escapeHtml(state.query)}” · ${results.length} 个结果` : '推荐示例'
  $('#searchMeta').innerHTML = queryLabel
  $('#searchResults').innerHTML = results.length
    ? results.map((track, index) => trackMarkup(track, index)).join('')
    : '<div class="no-results"><strong>没有找到匹配歌曲</strong><span>试试歌曲名、歌手名，或切换平台筛选。</span></div>'
  $$('#platformFilters .filter-chip').forEach(button => button.classList.toggle('is-selected', button.dataset.platform === state.platform))
}

function renderPlaylist() {
  $('#playlistCount').textContent = state.playlist.length
  $('#playlistTrackList').innerHTML = state.playlist.length
    ? state.playlist.map((track, index) => trackMarkup(track, index, true)).join('')
    : '<div class="no-results"><strong>歌单还是空的</strong><span>去搜索页面添加几首喜欢的歌吧。</span></div>'
}

function renderPlayer() {
  const track = state.current
  $('#playerTitle').textContent = track.title
  $('#playerArtist').textContent = track.artist
  $('#playerCover').className = `mini-cover ${track.cover}`
  $('#playerCover').innerHTML = `<span>${escapeHtml(track.title.slice(0, 2))}</span>`
  $('#playPause').textContent = state.playing ? 'Ⅱ' : '▶'
  $('#playPause').setAttribute('aria-label', state.playing ? '暂停演示歌曲' : '播放演示歌曲')
  $('#playerState').textContent = state.playing ? '演示播放中 · 未连接音源' : '演示模式 · 未连接音源'
  $('#progressFill').style.width = `${state.progress}%`
  $('#currentTime').textContent = formatTime(track.duration * state.progress / 100)
  $('#duration').textContent = formatTime(track.duration)
  $('#heroTrackTitle').textContent = track.title
  $('#heroTrackArtist').textContent = `${track.artist} · ${track.album}`
  $('#heroSource').textContent = `${track.source} · ${track.quality}`
  $('#heroCover').className = `signal-cover ${track.cover}`
  $('#heroCover').innerHTML = `<span class="cover-ring"></span><b>MM</b><small>MOUMUSIC<br>SELECTION</small>`
  $('#heroWaveform').classList.toggle('is-playing', state.playing)
}

function setView(view) {
  state.view = view
  $$('[data-page]').forEach(page => {
    const active = page.dataset.page === view
    page.classList.toggle('is-visible', active)
    page.hidden = !active
  })
  $$('[data-view]').forEach(button => button.classList.toggle('is-active', button.dataset.view === view))
  if (view === 'search') renderSearch()
  if (view === 'playlist') renderPlaylist()
  window.scrollTo({ top: 0, behavior: 'smooth' })
}

function showToast(message) {
  const toast = $('#toast')
  toast.textContent = message
  toast.classList.add('is-visible')
  clearTimeout(state.toastTimer)
  state.toastTimer = setTimeout(() => toast.classList.remove('is-visible'), 2600)
}

function openTrack(track) {
  state.current = track
  $('#modalTitle').textContent = track.title
  $('#modalArtist').textContent = `${track.artist} · ${track.album}`
  $('#modalSource').textContent = track.source
  $('#modalQuality').textContent = track.quality
  $('#modalLyrics').textContent = track.lyric
  $('#modalCover').className = `modal-cover ${track.cover}`
  $('#modalCover').innerHTML = `<span>${escapeHtml(track.title.slice(0, 2))}</span>`
  $('#trackModal').hidden = false
  document.body.style.overflow = 'hidden'
}

function closeModal() {
  $('#trackModal').hidden = true
  document.body.style.overflow = ''
}

function openSearchSheet() {
  $('#searchSheet').hidden = false
  $('#quickSearchInput').value = state.query
  setTimeout(() => $('#quickSearchInput').focus(), 0)
  document.body.style.overflow = 'hidden'
}

function closeSearchSheet() {
  $('#searchSheet').hidden = true
  document.body.style.overflow = ''
}

function renderQuickResults(query = '') {
  const normalized = query.trim().toLowerCase()
  const results = tracks.filter(track => !normalized || [track.title, track.artist, track.album].some(value => value.toLowerCase().includes(normalized))).slice(0, 5)
  $('#quickResults').innerHTML = results.length
    ? results.map(track => `<button class="quick-result" data-quick-track="${escapeHtml(track.id)}" type="button"><span class="track-thumb ${track.cover}">${track.title.slice(0, 1)}</span><span><strong>${escapeHtml(track.title)}</strong><span>${escapeHtml(track.artist)} · ${escapeHtml(track.album)}</span></span><em>${escapeHtml(track.source)}</em></button>`).join('')
    : '<span class="quick-hint">没有找到结果，试试其他关键词。</span>'
}

function addOrRemoveTrack(id) {
  const track = tracks.find(item => item.id === id)
  if (!track) return
  const index = state.playlist.findIndex(item => item.id === id)
  if (index >= 0) {
    state.playlist.splice(index, 1)
    showToast(`已从歌单移除《${track.title}》`)
  } else {
    state.playlist.push(track)
    showToast(`已加入歌单《${track.title}》`)
  }
  renderHome(); renderSearch(); renderPlaylist()
}

function playTrack(track, announce = true) {
  state.current = track
  state.playing = true
  state.progress = 0
  renderPlayer()
  if (announce) showToast(`正在演示播放《${track.title}》 · ${track.quality}`)
}

function importPlaylistFile(file) {
  if (!file) return
  const reader = new FileReader()
  reader.onload = () => {
    try {
      const parsed = JSON.parse(reader.result)
      const names = Array.isArray(parsed) ? parsed : Array.isArray(parsed.songs) ? parsed.songs : []
      const imported = names.map(item => typeof item === 'string' ? item : item?.title).filter(Boolean)
      const matched = tracks.filter(track => imported.some(name => name.includes(track.title) || track.title.includes(name)))
      matched.forEach(track => { if (!state.playlist.some(item => item.id === track.id)) state.playlist.push(track) })
      renderPlaylist(); renderHome(); renderSearch()
      showToast(matched.length ? `已导入 ${matched.length} 首演示歌曲` : '文件已读取，但没有匹配到演示曲目')
    } catch { showToast('演示导入仅支持 JSON 歌曲列表') }
  }
  reader.readAsText(file)
}

function applyTheme() {
  const saved = localStorage.getItem('moumusic-demo-theme')
  if (saved === 'light' || saved === 'dark') document.body.dataset.theme = saved
  else delete document.body.dataset.theme
}

document.addEventListener('click', event => {
  const viewButton = event.target.closest('[data-view]')
  if (viewButton) { setView(viewButton.dataset.view); return }

  const playButton = event.target.closest('[data-play-track]')
  if (playButton) { const track = tracks.find(item => item.id === playButton.dataset.playTrack); if (track) playTrack(track); return }
  const addButton = event.target.closest('[data-add-track]')
  if (addButton) { addOrRemoveTrack(addButton.dataset.addTrack); return }
  const row = event.target.closest('.track-row')
  if (row && !event.target.closest('button')) { const track = tracks.find(item => item.id === row.dataset.trackId); if (track) openTrack(track); return }
  const quickTrack = event.target.closest('[data-quick-track]')
  if (quickTrack) { const track = tracks.find(item => item.id === quickTrack.dataset.quickTrack); if (track) { closeSearchSheet(); openTrack(track) } return }
  const filter = event.target.closest('[data-platform]')
  if (filter) { state.platform = filter.dataset.platform; renderSearch(); return }
  if (event.target.closest('[data-close-modal]')) { closeModal(); return }
  if (event.target.closest('[data-close-search]')) { closeSearchSheet(); return }
  if (event.target.closest('#quickSearch')) { openSearchSheet(); renderQuickResults($('#quickSearchInput').value); return }
  if (event.target.closest('#themeToggle')) {
    const nextTheme = document.body.dataset.theme === 'dark' ? 'light' : 'dark'
    document.body.dataset.theme = nextTheme
    localStorage.setItem('moumusic-demo-theme', nextTheme)
    showToast(nextTheme === 'dark' ? '已切换到深色模式' : '已切换到浅色模式')
    return
  }
  if (event.target.closest('#playPause')) { state.playing = !state.playing; renderPlayer(); return }
  if (event.target.closest('#previousTrack') || event.target.closest('#nextTrack')) {
    const currentIndex = tracks.findIndex(track => track.id === state.current.id)
    const delta = event.target.closest('#previousTrack') ? -1 : 1
    playTrack(tracks[(currentIndex + delta + tracks.length) % tracks.length])
    return
  }
  if (event.target.closest('#lyricsButton')) { openTrack(state.current); return }
  if (event.target.closest('#modalPlay')) { closeModal(); playTrack(state.current); return }
  if (event.target.closest('#modalAdd')) { addOrRemoveTrack(state.current.id); return }
  if (event.target.closest('#importPlaylist')) { $('#playlistFile').click(); return }
  if (event.target.closest('#playPlaylist')) { if (state.playlist[0]) playTrack(state.playlist[0]); else showToast('歌单还是空的'); return }
  if (event.target.closest('[data-demo-source]')) { showToast('演示：音源管理会在 App 设置页中打开'); return }
  if (event.target.closest('[data-demo-mode]')) { showToast('演示：播放器模式可在 App 设置页切换'); return }
  const toggle = event.target.closest('.toggle')
  if (toggle) { toggle.classList.toggle('is-on'); toggle.setAttribute('aria-pressed', toggle.classList.contains('is-on')); showToast(toggle.classList.contains('is-on') ? '逐字歌词已开启' : '逐字歌词已关闭') }
})

$('#searchForm').addEventListener('submit', event => {
  event.preventDefault()
  state.query = $('#searchInput').value
  setView('search')
  showToast(state.query.trim() ? `正在展示 “${state.query.trim()}” 的演示结果` : '已显示推荐示例')
})

$('#quickSearchForm').addEventListener('submit', event => {
  event.preventDefault()
  const query = $('#quickSearchInput').value.trim()
  state.query = query
  closeSearchSheet()
  setView('search')
  $('#searchInput').value = query
  showToast(query ? `已搜索 “${query}”` : '已显示推荐示例')
})

$('#quickSearchInput').addEventListener('input', event => renderQuickResults(event.target.value))
$('#playlistFile').addEventListener('change', event => importPlaylistFile(event.target.files?.[0]))
$('#qualityDemo').addEventListener('change', event => showToast(`演示音质已切换为：${event.target.value}`))

document.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); openSearchSheet(); renderQuickResults('') }
  if (event.key === 'Escape') { closeModal(); closeSearchSheet() }
  if (event.key === 'Enter' && event.target.closest('.track-row')) { const track = tracks.find(item => item.id === event.target.closest('.track-row').dataset.trackId); if (track) openTrack(track) }
})

applyTheme()
renderHome()
renderSearch()
renderPlaylist()
renderPlayer()
setInterval(() => {
  if (!state.playing) return
  state.progress += 100 / Math.max(state.current.duration, 1)
  if (state.progress >= 100) { state.progress = 0; state.playing = false; showToast('演示歌曲播放结束') }
  renderPlayer()
}, 1000)
