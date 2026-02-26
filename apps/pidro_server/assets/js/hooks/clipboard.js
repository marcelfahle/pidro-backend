export const Clipboard = {
  mounted() {
    this.el.addEventListener('click', () => {
      let text = this.el.dataset.clipboardText
      if (!text && this.el.dataset.target) {
        const target = document.getElementById(this.el.dataset.target)
        text = target ? target.value : ''
      }
      if (text) {
        navigator.clipboard.writeText(text).then(() => {
          const original = this.el.textContent
          this.el.textContent = 'Copied!'
          setTimeout(() => {
            this.el.textContent = original
          }, 2000)
        })
      }
    })
  }
}
