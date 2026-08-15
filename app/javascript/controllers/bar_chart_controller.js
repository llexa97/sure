import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import { CHART_TOOLTIP_CLASSES } from "utils/chart_tooltip";

// Grouped bar chart used by the dashboard "money flow" widget and the annual
// analysis. The analysis can opt into account-colored stacked segments while
// the dashboard keeps its original single-color income/expense bars.
// Modeled after time_series_chart_controller's lifecycle (install/teardown,
// ResizeObserver, turbo:load reinstall, page-relative tooltip positioning)
// but with scaleBand/scaleLinear instead of a line.

// Breathing room between neighbouring month labels before they read as touching.
const LABEL_GAP_PX = 8;

export default class extends Controller {
  static values = {
    data: Array,
    currency: { type: String, default: "USD" },
    incomeLabel: { type: String, default: "Income" },
    expenseLabel: { type: String, default: "Expenses" },
    stacked: { type: Boolean, default: false },
  };

  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _teardown() {
    d3.select(this.element).selectAll("*").remove();
  }

  _install() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    const data = this.dataValue || [];

    if (width < 50 || height < 50 || data.length === 0) return;

    const margin = { top: 16, right: 4, bottom: 24, left: 4 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", [0, 0, width, height]);

    const group = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    const series = ["income", "expense"];
    const seriesColor = {
      expense: "var(--color-gray-400)",
      income: "var(--color-success)",
    };

    const x0 = d3
      .scaleBand()
      .domain(data.map((d) => d.label))
      .range([0, innerWidth])
      .padding(0.3);

    const x1 = d3
      .scaleBand()
      .domain(series)
      .range([0, x0.bandwidth()])
      .padding(0.15);

    const maxValue = d3.max(data, (d) => Math.max(d.income, d.expense)) || 1;
    const y = d3
      .scaleLinear()
      .domain([0, maxValue * 1.1])
      .range([innerHeight, 0]);
    // Floor tiny-but-nonzero bars (e.g. an in-progress month) at 2px so they stay visible.
    const barHeight = (v) => (v > 0 ? Math.max(2, innerHeight - y(v)) : 0);

    const tooltip = d3
      .select(this.element)
      .append("div")
      .attr("class", `${CHART_TOOLTIP_CLASSES} opacity-0 top-0`);

    const showTooltip = (event, month, key, segment = null) => {
      const estimatedTooltipWidth = 200;
      const pageWidth = document.body.clientWidth;
      const tooltipX = event.pageX + 10;
      const overflowX = tooltipX + estimatedTooltipWidth - pageWidth;
      const adjustedX = overflowX > 0 ? event.pageX - overflowX - 20 : tooltipX;

      tooltip
        .html(this._tooltipTemplate(month, key, segment))
        .style("opacity", 1)
        .style("left", `${adjustedX}px`)
        .style("top", `${event.pageY - 10}px`);
    };

    const hideTooltip = () => tooltip.style("opacity", 0);

    const monthGroups = group
      .selectAll("g.month")
      .data(data)
      .join("g")
      .attr("class", "month")
      .attr("transform", (d) => `translate(${x0(d.label)},0)`);

    const seriesGroups = monthGroups
      .selectAll("g.series")
      .data((month) => series.map((key) => ({ key, month, value: month[key] })))
      .join("g")
      .attr("class", "series")
      .attr("transform", (d) => `translate(${x1(d.key)},0)`);

    seriesGroups
      .selectAll("rect")
      .data((d) =>
        this._segmentsFor({
          month: d.month,
          key: d.key,
          totalHeight: barHeight(d.value),
          innerHeight,
          fallbackColor: seriesColor[d.key],
        }),
      )
      .join("rect")
      .attr("x", 0)
      .attr("y", (d) => d.y)
      .attr("width", x1.bandwidth())
      .attr("height", (d) => d.height)
      .attr("rx", (d) => (d.account ? 1 : 3))
      .attr("fill", (d) => d.color)
      .attr("fill-opacity", (d) => d.opacity)
      .on("mousemove", (event, d) => showTooltip(event, d.month, d.key, d))
      .on("mouseleave", hideTooltip);

    const axisLabels = group
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x0).tickSize(0))
      .call((g) => g.select(".domain").remove())
      .selectAll("text")
      .attr("class", (_d, i) =>
        data[i].highlighted
          ? "text-primary fill-current"
          : "text-secondary fill-current",
      )
      .style("font-size", "12px")
      .style("font-weight", (_d, i) => (data[i].highlighted ? 600 : 500));

    this._fitAxisLabels(axisLabels, data, x0.step());
  }

  // The month labels are sized by the locale, not by the chart: "Mar 2026" fits
  // a phone, "Mar de 2026" (ca/es/pt) does not and overlaps its neighbours.
  // Measure what actually rendered and step down until it fits — full label,
  // then the abbreviated month, then every other tick. Measuring beats guessing
  // at a character width, which varies by locale, font and zoom.
  _fitAxisLabels(labels, data, step) {
    if (labels.empty()) return;

    const widest = () =>
      d3.max(labels.nodes(), (node) => node.getComputedTextLength()) || 0;
    const fits = () => widest() <= step - LABEL_GAP_PX;

    if (fits()) return;

    labels.text((_d, i) => data[i].short_label ?? data[i].label);
    if (fits()) return;

    // Still too wide (a very narrow column): thin out rather than overlap.
    // The parity is taken from the highlighted month rather than fixed at even,
    // so that month survives without being an exception to the pattern — it
    // sits last (build_money_flow_data counts down to the selected month), and
    // keeping it on top of every even index left the final two labels one step
    // apart, the very spacing that had just been measured as too tight.
    const highlightedIndex = data.findIndex((d) => d.highlighted);
    const keepParity = highlightedIndex >= 0 ? highlightedIndex % 2 : 0;
    labels.style("display", (_d, i) => (i % 2 === keepParity ? null : "none"));
  }

  _segmentsFor({ month, key, totalHeight, innerHeight, fallbackColor }) {
    if (!this.stackedValue) {
      return [
        {
          month,
          key,
          value: month[key],
          y: innerHeight - totalHeight,
          height: totalHeight,
          color: fallbackColor,
          opacity: month.partial ? 0.5 : 1,
        },
      ];
    }

    const accounts = (month.accounts || [])
      .map((account) => ({ ...account, value: Number(account[key]) || 0 }))
      .filter((account) => account.value > 0);
    const accountTotal = d3.sum(accounts, (account) => account.value);

    if (accountTotal <= 0 || totalHeight <= 0) return [];

    let stackedHeight = 0;
    return accounts.map((account, index) => {
      // Assign any floating-point remainder to the last segment so all account
      // pieces exactly fill the original monthly total bar.
      const height =
        index === accounts.length - 1
          ? totalHeight - stackedHeight
          : totalHeight * (account.value / accountTotal);
      stackedHeight += height;

      return {
        month,
        key,
        account,
        value: account.value,
        percentage: Number(account[`${key}_percentage`]) || 0,
        y: innerHeight - stackedHeight,
        height,
        color: account.color,
        // Position differentiates the two bar types; the lighter right-hand
        // stack adds a second cue without changing an account's assigned hue.
        opacity: (key === "expense" ? 0.65 : 1) * (month.partial ? 0.6 : 1),
      };
    });
  }

  _tooltipTemplate(month, key, segment = null) {
    const label =
      key === "income" ? this.incomeLabelValue : this.expenseLabelValue;
    const color =
      segment?.color ||
      (key === "income" ? "var(--color-success)" : "var(--color-gray-400)");
    const accountName = segment?.account?.name;
    const value = segment?.value ?? month[key];
    const percentage = accountName
      ? `<span class="text-secondary">(${this._formatPercentage(segment.percentage)})</span>`
      : "";

    return `
      <div class="text-xs text-secondary mb-1">${this._escapeHtml(month.label)}</div>
      ${accountName ? `<div class="text-xs text-primary font-medium mb-1">${this._escapeHtml(accountName)}</div>` : ""}
      <div class="flex items-center gap-1.5 text-primary font-medium tabular-nums">
        <span class="inline-block w-2 h-2 rounded-full" style="background-color: ${this._escapeHtml(color)};"></span>
        ${this._escapeHtml(label)}: ${this._formatCurrency(value)} ${percentage}
      </div>
    `;
  }

  _formatPercentage(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "percent",
        maximumFractionDigits: 1,
      }).format((Number(value) || 0) / 100);
    } catch {
      return `${value}%`;
    }
  }

  _formatCurrency(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue,
        maximumFractionDigits: 0,
      }).format(value);
    } catch {
      return value;
    }
  }

  _escapeHtml(value) {
    return String(value ?? "").replace(
      /[&<>"']/g,
      (character) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#039;",
        })[character],
    );
  }
}
