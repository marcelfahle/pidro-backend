const openButton = document.querySelector("[data-open-ios]");

if (openButton) {
  let fallbackTimer;

  const cancelFallback = () => {
    window.clearTimeout(fallbackTimer);
  };

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) cancelFallback();
  });
  window.addEventListener("pagehide", cancelFallback);

  openButton.addEventListener("click", (event) => {
    event.preventDefault();
    cancelFallback();

    const fallbackMessage = document.querySelector("[data-ios-fallback]");

    window.location.assign(openButton.href);

    fallbackTimer = window.setTimeout(() => {
      if (document.visibilityState !== "visible") return;
      if (fallbackMessage) fallbackMessage.hidden = false;
    }, 1500);
  });
}
