export const Clipboard = {
  mounted() {
    this.el.addEventListener('click', () => {
      const text = this.el.dataset.clipboardText
      navigator.clipboard.writeText(text).then(() => {
        this.pushEvent('clipboard_copied', {})
        // Reset feedback after 2 seconds
        setTimeout(() => {
          this.pushEvent('reset_clipboard_feedback', {})
        }, 2000)
      })
    })
  }
}
