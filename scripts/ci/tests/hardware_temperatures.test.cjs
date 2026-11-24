const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const page = fs.readFileSync(path.join(__dirname, "../../../k8s/apps/claude-system/cockpit/index.html"), "utf8");
const moduleCode = page.match(/<script type="module">([\s\S]*?)<\/script>/)[1];
const storage = new Map();
const context = vm.createContext({
  LitElement: class {},
  customElements: { define() {} },
  localStorage: { getItem: (key) => storage.get(key) },
});
vm.runInContext(moduleCode.replace(/^import .*;$/gm, ""), context);
const { hardwareWindow, hardwareRows, hardwareWarnings, temperatureViolation, HARDWARE_COMPONENTS } = vm.runInContext(
  "({ hardwareWindow, hardwareRows, hardwareWarnings, temperatureViolation, HARDWARE_COMPONENTS })", context,
);

test("invalid saved history windows fall back to 24h", () => {
  assert.equal(hardwareWindow(), "24h");
  storage.set("cockpit.hardware", "7d");
  assert.equal(hardwareWindow(), "7d");
  storage.set("cockpit.hardware", "1m");
  assert.equal(hardwareWindow(), "24h");
});

test("recovered low temperatures still warn, and unsupported sensors have no reading", () => {
  const nodes = hardwareRows({ hardware_temperatures: [{
    node: "talos-one",
    sensors: [
      { component: "coretemp", stat: "current", value: 56 },
      { component: "coretemp", stat: "min", value: 0 },
      { component: "coretemp", stat: "max", value: 68 },
      { component: "coretemp", stat: "coverage", value: 0.5 },
    ],
  }] });
  const [cpu, , ram] = nodes[0].rows;
  assert.equal(nodes[0].node, "talos-one");
  assert.equal(cpu.cells[0].violation, null);
  assert.equal(cpu.cells[1].value, 0);
  assert.equal(cpu.cells[1].violation.state, "warn");
  assert.equal(cpu.partial, true);
  assert.ok(ram.cells.every(({ value, violation }) => value === undefined && violation === null));
  assert.equal(hardwareWarnings(nodes).text, "Temperature warning in history");
});

test("high warning and critical boundaries match all hardware rules", () => {
  for (const [index, [warn, critical]] of [[80, 95], [65, 75], [70, 85]].entries()) {
    const component = HARDWARE_COMPONENTS[index];
    for (const stat of ["current", "max"]) {
      assert.equal(temperatureViolation(warn, stat, component), null);
      assert.equal(temperatureViolation(warn + 1, stat, component).state, "warn");
      assert.equal(temperatureViolation(critical, stat, component).state, "warn");
      assert.equal(temperatureViolation(critical + 1, stat, component).state, "bad");
    }
    assert.equal(temperatureViolation(5, "min", component), null);
    assert.equal(temperatureViolation(4, "min", component).state, "warn");
    assert.equal(temperatureViolation(null, "current", component), null);
  }
});
