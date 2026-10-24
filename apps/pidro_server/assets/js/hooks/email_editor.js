export const EmailEditor = {
  mounted() {
    this.body = this.el.querySelector("[data-email-body]")
    this.source = this.el.querySelector("[data-email-source]")
    this.hiddenHtml = this.el.querySelector("[data-email-hidden-html]")
    this.dirty = this.el.querySelector("[data-editor-dirty]")
    this.fields = Array.from(this.el.querySelectorAll("[data-email-field]"))
    this.savedRange = null

    this.bindEditor()
    this.syncHiddenFields()
  },

  bindEditor() {
    this.el.addEventListener("submit", () => this.syncHiddenFields())

    this.fields.forEach(field => {
      field.addEventListener("input", () => this.showDirtyState(true))
    })

    this.body.addEventListener("input", () => this.persistAndRender())
    this.body.addEventListener("keyup", () => this.saveSelection())
    this.body.addEventListener("mouseup", () => this.saveSelection())
    this.body.addEventListener("focus", () => this.saveSelection())

    this.el.addEventListener("click", event => {
      const button = event.target.closest("[data-editor-command], [data-editor-variable], [data-editor-action]")
      if (!button || button.disabled) return
      event.preventDefault()
      if (button.dataset.editorCommand) {
        this.runCommand(button.dataset.editorCommand, button.dataset.editorValue)
      } else if (button.dataset.editorVariable) {
        this.insertText(button.dataset.editorVariable)
      } else {
        this.runAction(button.dataset.editorAction, button)
      }
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
    this.showDirtyState(true)
    if (this.syncHiddenFields()) {
      this.hiddenHtml.dispatchEvent(new Event("input", {bubbles: true}))
    }
  },

  fieldValue(key) {
    const field = this.el.querySelector(`[data-email-field="${key}"]`)
    return field ? field.value : ""
  },

  syncHiddenFields() {
    if (this.hiddenHtml.value === this.body.innerHTML) return false
    this.hiddenHtml.value = this.body.innerHTML
    return true
  },

  copyHtml(button) {
    const html = this.source.value
    navigator.clipboard.writeText(html).then(() => {
      const original = button.innerHTML
      button.textContent = "Copied"
      setTimeout(() => {
        button.innerHTML = original
      }, 1400)
    })
  },

  downloadHtml() {
    const filename = `${this.slugify(this.fieldValue("name") || "pidro-email")}.html`
    const blob = new Blob([this.source.value], {type: "text/html"})
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

  slugify(value) {
    return String(value)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "") || "pidro-email"
  }
}
