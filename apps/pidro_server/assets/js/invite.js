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

    const fallbackUrl = openButton.dataset.storeUrl;
    const fallbackMessage = document.querySelector("[data-ios-fallback]");

    window.location.assign(openButton.href);

    fallbackTimer = window.setTimeout(() => {
      if (document.visibilityState !== "visible") return;
      if (fallbackMessage) fallbackMessage.hidden = false;
      if (fallbackUrl) window.location.assign(fallbackUrl);
    }, 1500);
  });
}
