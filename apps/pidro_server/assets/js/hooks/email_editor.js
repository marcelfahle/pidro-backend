export const EmailEditor = {
  mounted() {
    this.body = this.el.querySelector("[data-email-body]")
    this.preview = this.el.querySelector("[data-email-preview]")
    this.source = this.el.querySelector("[data-email-source]")
    this.hiddenHtml = this.el.querySelector("[data-email-hidden-html]")
    this.dirty = this.el.querySelector("[data-editor-dirty]")
    this.fields = Array.from(this.el.querySelectorAll("[data-email-field]"))
    this.savedRange = null

    this.bindEditor()
    this.syncHiddenFields()
    this.renderOutput()
  },

  bindEditor() {
    this.el.addEventListener("submit", () => this.syncHiddenFields())

    this.fields.forEach(field => {
      field.addEventListener("input", () => this.persistAndRender())
    })

    this.body.addEventListener("input", () => this.persistAndRender())
    this.body.addEventListener("keyup", () => this.saveSelection())
    this.body.addEventListener("mouseup", () => this.saveSelection())
    this.body.addEventListener("focus", () => this.saveSelection())

    this.el.querySelectorAll("[data-editor-command]").forEach(button => {
      button.addEventListener("click", event => {
        event.preventDefault()
        this.runCommand(button.dataset.editorCommand, button.dataset.editorValue)
      })
    })

    this.el.querySelectorAll("[data-editor-variable]").forEach(button => {
      button.addEventListener("click", event => {
        event.preventDefault()
        this.insertText(button.dataset.editorVariable)
      })
    })

    this.el.querySelectorAll("[data-editor-action]").forEach(button => {
      button.addEventListener("click", event => {
        event.preventDefault()
        this.runAction(button.dataset.editorAction, button)
      })
    })
  },

  runCommand(command, value = null) {
    this.restoreSelection()
    this.body.focus()
    document.execCommand(command, false, value)
    this.saveSelection()
    this.persistAndRender()
  },

  runAction(action, button) {
    if (action === "create-link") {
      const href = window.prompt("Link URL")
      if (href) this.runCommand("createLink", href)
      return
    }

    if (action === "copy-html") {
      this.copyHtml(button)
      return
    }

    if (action === "download-html") {
      this.downloadHtml()
    }
  },

  insertText(text) {
    this.restoreSelection()
    this.body.focus()
    document.execCommand("insertText", false, text)
    this.saveSelection()
    this.persistAndRender()
  },

  saveSelection() {
    const selection = window.getSelection()
    if (!selection || selection.rangeCount === 0) return

    const range = selection.getRangeAt(0)
    if (this.body.contains(range.commonAncestorContainer)) {
      this.savedRange = range
    }
  },

  restoreSelection() {
    if (!this.savedRange) return

    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(this.savedRange)
  },

  persistAndRender() {
    this.markEmptyState()
    this.syncHiddenFields()
    this.showDirtyState(true)
    this.renderOutput()
  },

  currentDraft() {
    return {
      name: this.fieldValue("name"),
      subject: this.fieldValue("subject"),
      preview: this.fieldValue("preview"),
      fromName: this.fieldValue("fromName"),
      fromEmail: this.fieldValue("fromEmail"),
      replyTo: this.fieldValue("replyTo"),
      html: this.body.innerHTML
    }
  },

  fieldValue(key) {
    const field = this.el.querySelector(`[data-email-field="${key}"]`)
    return field ? field.value : ""
  },

  syncHiddenFields() {
    if (this.hiddenHtml) this.hiddenHtml.value = this.body.innerHTML
  },

  renderOutput() {
    const draft = this.currentDraft()
    const html = this.fullEmailHtml(draft)

    if (this.preview) this.preview.srcdoc = html
    if (this.source) this.source.value = html
  },

  fullEmailHtml(draft) {
    return `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${this.escapeHtml(draft.subject)}</title>
  </head>
  <body style="margin:0;padding:0;background:#f5f5f4;color:#1c1917;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
    <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">${this.escapeHtml(draft.preview)}</div>
    <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f5f5f4;padding:24px 12px;">
      <tr>
        <td align="center">
          <table role="presentation" width="640" cellspacing="0" cellpadding="0" style="width:100%;max-width:640px;background:#ffffff;border:1px solid #e7e5e4;">
            <tr>
              <td style="padding:32px;font-size:16px;line-height:1.6;">
                ${draft.html}
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`
  },

  copyHtml(button) {
    const html = this.fullEmailHtml(this.currentDraft())
    navigator.clipboard.writeText(html).then(() => {
      const original = button.innerHTML
      button.textContent = "Copied"
      setTimeout(() => {
        button.innerHTML = original
      }, 1400)
    })
  },

  downloadHtml() {
    const draft = this.currentDraft()
    const filename = `${this.slugify(draft.name || "pidro-email")}.html`
    const blob = new Blob([this.fullEmailHtml(draft)], {type: "text/html"})
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")

    link.href = url
    link.download = filename
    document.body.appendChild(link)
    link.click()
    link.remove()
    URL.revokeObjectURL(url)
  },

  markEmptyState() {
    const empty = this.body.innerText.trim() === ""
    this.body.dataset.empty = empty ? "true" : "false"
  },

  showDirtyState(show) {
    if (!this.dirty) return
    this.dirty.classList.toggle("hidden", !show)
  },

  escapeHtml(value) {
    return String(value || "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;")
  },

  slugify(value) {
    return String(value)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "") || "pidro-email"
  }
}
