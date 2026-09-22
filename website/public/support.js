(() => {
  const configElement = document.getElementById('site-config')
  let config = {}
  try {
    config = JSON.parse(configElement?.textContent || '{}')
  } catch {
    config = {}
  }

  const i18n = window.MoumusicI18n || { t: key => key }
  const planUrl = config.afdianPlanUrl || config.afdianUrl || 'https://ifdian.net/a/moumou2026/plan'
  const creatorUrl = config.afdianUrl || 'https://ifdian.net/a/moumou2026'
  const dialog = document.getElementById('afdian-payment-dialog')
  const frame = document.getElementById('afdian-payment-frame')
  const directLink = document.getElementById('afdian-direct-link')
  const planChoice = document.getElementById('afdian-plan-choice')
  const customChoice = document.getElementById('afdian-custom-choice')
  const modeLabel = document.getElementById('afdian-payment-mode')

  function setMode(mode) {
    const isCustom = mode === 'custom'
    const targetUrl = isCustom ? creatorUrl : planUrl
    if (frame && frame.src !== targetUrl) frame.src = targetUrl
    if (directLink) directLink.href = targetUrl
    planChoice?.classList.toggle('is-selected', !isCustom)
    customChoice?.classList.toggle('is-selected', isCustom)
    if (modeLabel) {
      modeLabel.textContent = isCustom
        ? i18n.t('supportDialog.customHint')
        : i18n.t('supportDialog.planHint')
    }
  }

  function closeDialog() {
    if (!dialog) return
    if (dialog.open && typeof dialog.close === 'function') dialog.close()
    else dialog.removeAttribute('open')
  }

  function openDialog(event) {
    if (!dialog || !frame) return
    event?.preventDefault()
    setMode('plan')
    if (typeof dialog.showModal === 'function') dialog.showModal()
    else dialog.setAttribute('open', '')
  }

  document.querySelectorAll('[data-support-action], #install-support, #install-support-hero').forEach(link => {
    link.href = planUrl
    link.addEventListener('click', openDialog)
  })

  document.getElementById('afdian-dialog-close')?.addEventListener('click', closeDialog)
  planChoice?.addEventListener('click', () => setMode('plan'))
  customChoice?.addEventListener('click', () => setMode('custom'))
  dialog?.addEventListener('click', event => {
    if (event.target === dialog) closeDialog()
  })
})()
