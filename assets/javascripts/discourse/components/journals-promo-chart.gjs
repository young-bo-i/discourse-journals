import Component from "@glimmer/component";
import { modifier } from "ember-modifier";
import loadChartJS from "discourse/lib/load-chart-js";

// Thin wrapper around Chart.js (lazy-loaded via core) so the plugin's admin
// template can render a line chart without depending on the admin bundle.
// Re-instantiates whenever @config changes.
export default class JournalsPromoChart extends Component {
  renderChart = modifier((element) => {
    let chart;
    let destroyed = false;

    const config = this.args.config;
    if (config) {
      loadChartJS().then((Chart) => {
        if (destroyed) {
          return;
        }
        chart = new Chart(element.getContext("2d"), config);
      });
    }

    return () => {
      destroyed = true;
      chart?.destroy();
    };
  });

  <template>
    <div class="dj-promo-chart">
      <canvas {{this.renderChart}}></canvas>
    </div>
  </template>
}
