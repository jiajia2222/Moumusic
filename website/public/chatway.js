(() => {
  const configElement = document.getElementById('site-config')
  let config = {}
  try {
    config = JSON.parse(configElement?.textContent || '{}')
  } catch {
    config = {}
  }

  const scriptId = config.chatwayScriptId || 'Ol4m4dkJ9UJP'
  const widgetId = config.chatwayWidgetId || 'qfybc7qkscn3ptkgxwrv'
  const fallbackButton = document.getElementById('chatway-fallback')
  const dialog = document.getElementById('chatway-dialog')
  const frame = document.getElementById('chatway-fallback-frame')
  const widgetUrl = `https://widget.chatway.app/?userId=${encodeURIComponent(scriptId)}&widgetId=${encodeURIComponent(widgetId)}&bg-color=%230446DE`
  let chatwayReady = false

  function closeDialog() {
    if (!dialog) return
    if (dialog.open && typeof dialog.close === 'function') dialog.close()
    else dialog.removeAttribute('open')
  }

  function openDialog(event) {
    event?.preventDefault()
    if (!dialog || !frame) return
    if (frame.src !== widgetUrl) frame.src = widgetUrl
    if (typeof dialog.showModal === 'function') dialog.showModal()
    else dialog.setAttribute('open', '')
  }

  function hasNativeWidget() {
    return Boolean(document.querySelector('.chatway--container, #chatway_widget_trigger, [data-chatway-widget]'))
  }

  function markReady() {
    chatwayReady = true
    if (fallbackButton) fallbackButton.hidden = true
  }

  function showFallbackIfNeeded() {
    if (!chatwayReady && !hasNativeWidget() && fallbackButton) fallbackButton.hidden = false
  }

  fallbackButton?.addEventListener('click', openDialog)
  document.getElementById('chatway-dialog-close')?.addEventListener('click', closeDialog)
  dialog?.addEventListener('click', event => {
    if (event.target === dialog) closeDialog()
  })
  document.addEventListener('chatwayLoaded', markReady, { once: true })
  window.addEventListener('load', () => window.setTimeout(showFallbackIfNeeded, 4500), { once: true })

  if (typeof MutationObserver === 'function') {
    const observer = new MutationObserver(() => {
      if (hasNativeWidget()) {
        markReady()
        observer.disconnect()
      }
    })
    observer.observe(document.documentElement, { childList: true, subtree: true })
    window.setTimeout(() => observer.disconnect(), 12_000)
  }
})()
