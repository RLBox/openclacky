// Keeps enterprise-managed model policy fresh without repeating device login.
const EnterpriseModels = (() => {
  const MIN_REFRESH_INTERVAL_MS = 60 * 1000;
  const BACKGROUND_REFRESH_INTERVAL_MS = 5 * 60 * 1000;
  let inFlight = null;
  let lastAttemptAt = 0;
  let timer = null;

  async function refresh({ force = false, notify = false } = {}) {
    const now = Date.now();
    if (!force && now - lastAttemptAt < MIN_REFRESH_INTERVAL_MS) {
      return { ok: true, skipped: true };
    }
    if (inFlight) return inFlight;

    lastAttemptAt = now;
    inFlight = (async () => {
      try {
        const response = await fetch("/api/enterprise/models/refresh", { method: "POST" });
        const data = await response.json().catch(() => ({}));
        if (!response.ok || !data.ok) {
          if (notify && Clacky.Modal && Clacky.Modal.toast) {
            Clacky.Modal.toast(I18n.t("settings.enterprise.models.failed"), "error");
          }
          return { ok: false, error: data.error || `HTTP ${response.status}` };
        }

        if (data.changed) {
          document.dispatchEvent(new CustomEvent("enterprise-models:refreshed", { detail: data }));
          if (notify && Clacky.Modal && Clacky.Modal.toast) {
            Clacky.Modal.toast(I18n.t("settings.enterprise.models.updated", {
              count: data.model_count || 0
            }), "success");
          }
        }
        return data;
      } catch (error) {
        if (notify && Clacky.Modal && Clacky.Modal.toast) {
          Clacky.Modal.toast(I18n.t("settings.enterprise.models.failed"), "error");
        }
        return { ok: false, error: error.message };
      } finally {
        inFlight = null;
      }
    })();
    return inFlight;
  }

  function start() {
    if (timer) return;
    refresh();
    timer = setInterval(() => refresh(), BACKGROUND_REFRESH_INTERVAL_MS);
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) refresh();
    });
  }

  return { refresh, start };
})();

Clacky.EnterpriseModels = EnterpriseModels;
