(() => {
  const thresholds = {
    Io: {
      cpu: [70, 90],
      mem: [75, 90],
      disk: [80, 90],
      temp: [70, 80],
    },

    Jupiter: {
      cpu: [70, 90],
      mem: [75, 90],
      disk: [80, 90],
      temp: [80, 90],
    },
  };

  /*
   * Based on your current Glances configuration:
   *
   * 0 = CPU
   * 1 = Memory
   * 2 = Disk
   * 3 = CPU temperature
   * 4 = Uptime
   */
  const metricOrder = ["cpu", "mem", "disk", "temp", "uptime"];

  const severity = {
    nominal: 0,
    warning: 1,
    critical: 2,
  };

  function getStatus(value, [warning, critical]) {
    if (value >= critical) return "critical";
    if (value >= warning) return "warning";
    return "nominal";
  }

  function getUsagePercentage(resource) {
    const bar = resource.querySelector(".resource-usage > div");

    if (!bar) {
      return NaN;
    }

    return parseFloat(bar.style.width);
  }

  function getTemperature(resource) {
    const match = resource.textContent.match(
      /(-?\d+(?:[.,]\d+)?)\s*°?\s*C/i
    );

    if (!match) {
      return NaN;
    }

    return parseFloat(match[1].replace(",", "."));
  }

  function updateGlancesCard(card) {
    const host = card
      .querySelector(".information-widget-label")
      ?.textContent?.trim();

    if (!host || !thresholds[host]) {
      return;
    }

    const hostThresholds = thresholds[host];

    const resources = card.querySelectorAll(
      ".information-widget-resource"
    );

    let worstStatus = "nominal";

    resources.forEach((resource, index) => {
      const metric = metricOrder[index];

      resource.removeAttribute("data-health");

      if (!metric || metric === "uptime") {
        return;
      }

      const metricThresholds = hostThresholds[metric];

      if (!metricThresholds) {
        return;
      }

      const value =
        metric === "temp"
          ? getTemperature(resource)
          : getUsagePercentage(resource);

      if (!Number.isFinite(value)) {
        return;
      }

      const status = getStatus(value, metricThresholds);

      resource.dataset.health = status;

      if (severity[status] > severity[worstStatus]) {
        worstStatus = status;
      }
    });

    card.dataset.health = worstStatus;
  }

  function updateGlancesStatus() {
    document
      .querySelectorAll(".information-widget-glances")
      .forEach(updateGlancesCard);
  }

  updateGlancesStatus();

  /*
   * Glances refreshes regularly, so reevaluate the current values.
   */
  setInterval(updateGlancesStatus, 2000);
})();
