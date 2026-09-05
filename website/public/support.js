(() => {
  const configElement = document.getElementById('site-config')
  let config = {}
  try {
    config = JSON.parse(configElement?.textContent || '{}')
  } catch {
    config = {}
  }

  const planUrl = config.afdianPlanUrl || config.afdianUrl || 'https://ifdian.net/a/moumou2026/plan'
  const dialog = document.getElementById('afdian-payment-dialog')
  const frame = document.getElementById('afdian-payment-frame')
  const directLink = document.getElementById('afdian-direct-link')

  function closeDialog() {
    if (!dialog) return
    if (dialog.open && typeof dialog.close === 'function') dialog.close()
    else dialog.removeAttribute('open')
  }

  function openDialog(event) {
    if (!dialog || !frame) return
    event?.preventDefault()
    if (frame.src !== planUrl) frame.src = planUrl
    if (directLink) directLink.href = planUrl
    if (typeof dialog.showModal === 'function') dialog.showModal()
    else dialog.setAttribute('open', '')
  }

  document.querySelectorAll('[data-support-action], #install-support, #install-support-hero').forEach(link => {
    link.href = planUrl
    link.addEventListener('click', openDialog)
  })

  document.getElementById('afdian-dialog-close')?.addEventListener('click', closeDialog)
  dialog?.addEventListener('click', event => {
    if (event.target === dialog) closeDialog()
  })
})()
