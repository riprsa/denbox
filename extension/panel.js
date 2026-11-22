// The box panel, a page of the extension: memory, CPU and traffic, the
// supervised services with restart and on/off for optional ones, and the
// listening ports. It reads GET /state of the box address every few seconds
// while the page is visible and stops while it is hidden.
//
// Everything the box answers is data that someone else may have written. It
// reaches the page only as text nodes, textContent and numbers: no markup, no
// href, src or style, no code. tests/panel.test.cjs holds it to that.
const INTERVAL = 3000;
const $ = (id) => document.getElementById(id);
let api = null;

// el("td", { className: "num" }, "text", child) builds an element. `props`
// are always literals of this file; children that are not nodes become text.
function el(tag, props = {}, ...children) {
  const node = Object.assign(document.createElement(tag), props);
  node.append(...children.filter((child) => child !== null && child !== undefined));
  return node;
}
const row = (...cells) => el("tr", {}, ...cells.map((cell) => (cell instanceof Node && cell.tagName === "TD" ? cell : el("td", {}, cell))));

const UNITS = ["B", "KiB", "MiB", "GiB", "TiB"];
function bytes(value) {
  if (value === null || value === undefined) return "-";
  let unit = 0;
  while (Math.abs(value) >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit && value < 10 ? 1 : 0)} ${UNITS[unit]}`;
}
const rate = (value) => (value === null || value === undefined ? "-" : `${bytes(value)}/s`);
function duration(seconds) {
  const parts = [
    [Math.floor(seconds / 86400), "d"],
    [Math.floor(seconds / 3600) % 24, "h"],
    [Math.floor(seconds / 60) % 60, "m"],
    [seconds % 60, "s"],
  ];
  const first = parts.findIndex(([count]) => count > 0);
  return first < 0 ? "0s" : parts.slice(first, first + 2).map(([count, unit]) => `${count}${unit}`).join(" ");
}
const bar = (fraction) => el("meter", { min: 0, max: 1, value: Number(fraction) });

// A section reported as { state: "unavailable", reason } shows the reason in place.
const unavailable = (section) => section && !Array.isArray(section) && section.state === "unavailable";

function showSystem(system) {
  if (unavailable(system)) return $("system").replaceChildren(el("span", { className: "bad" }, system.reason));
  const { memory, cpu, network } = system;
  const limit = memory.limitBytes;
  const cpuLimit = cpu.limitCores === null ? "" : ` of ${(cpu.limitCores * 100).toFixed(0)}%`;
  $("system").replaceChildren(
    el(
      "table",
      {},
      row(
        "Memory",
        el("td", { className: "num" }, `${bytes(memory.usedBytes)}${limit === null ? "" : ` / ${bytes(limit)}`}`),
        el("td", { className: "wide" }, limit === null ? null : bar(memory.usedBytes / limit), " ",
          el("span", { className: "muted" }, `anon ${bytes(memory.anonBytes)}, file ${bytes(memory.fileBytes)}`)),
      ),
      row(
        "CPU",
        el("td", { className: "num" }, cpu.percent === null ? "-" : `${cpu.percent.toFixed(1)}%${cpuLimit}`),
        el("td", { className: "wide" }, cpu.percent === null || cpu.limitCores === null ? null : bar(cpu.percent / 100 / cpu.limitCores)),
      ),
      row(
        "Traffic",
        el("td", { className: "num" }, `in ${rate(network.rxBytesPerSecond)}, out ${rate(network.txBytesPerSecond)}`),
        el("td", { className: "wide muted" }, `total in ${bytes(network.rxBytes)}, out ${bytes(network.txBytes)}`),
      ),
      row("Uptime", el("td", { className: "num" }, duration(system.uptimeSeconds)), el("td", { className: "wide" })),
    ),
  );
}

// Names of services with a request in flight; their buttons stay disabled.
const busy = new Set();

// Sends one service action and refreshes; a failure shows next to the heading.
async function act(name, path, body) {
  busy.add(name);
  render();
  try {
    const reply = await api(path, body);
    $("services-note").className = "muted";
    $("services-note").textContent = reply?.restarting ? `restarting ${reply.restarting.join(", ")}` : "";
  } catch (error) {
    $("services-note").className = "bad";
    $("services-note").textContent = `${name}: ${message(error)}`;
  } finally {
    busy.delete(name);
    void refresh();
  }
}

function showServices(services) {
  $("restart-all").disabled = unavailable(services) || busy.has("all");
  if (unavailable(services)) return $("services").replaceChildren(el("span", { className: "bad" }, services.reason));
  $("services").replaceChildren(
    el(
      "table",
      {},
      ...services.map((service) => {
        const off = service.optional && !service.enabled;
        const state = off ? "off" : service.up ? `up ${duration(service.seconds)}` : `down ${duration(service.seconds)}`;
        const restart = el("button", { textContent: "Restart", disabled: busy.has(service.name) || off });
        restart.addEventListener("click", () => act(service.name, "/services/restart", { name: service.name }));
        let toggle = null;
        if (service.optional) {
          toggle = el("button", { textContent: service.enabled ? "Turn off" : "Turn on", disabled: busy.has(service.name) });
          toggle.addEventListener("click", () => act(service.name, "/services/toggle", { name: service.name, on: !service.enabled }));
        }
        return row(
          service.name,
          el("td", { className: off ? "muted" : service.up ? "" : "down" }, state),
          el("td", {}, restart),
          el("td", { className: "wide" }, toggle),
        );
      }),
    ),
  );
}

function showPorts(ports) {
  if (unavailable(ports)) return $("ports").replaceChildren(el("span", { className: "bad" }, ports.reason));
  $("ports").replaceChildren(
    el(
      "table",
      {},
      ...ports.map((port) =>
        row(el("td", { className: "num" }, String(port.port)), port.address, el("td", { className: "wide" + (port.process ? "" : " muted") }, port.process ?? "-")),
      ),
    ),
  );
}

let state = null;

// Shows each section; one whose data has an unexpected shape says so in place.
function render() {
  if (!state) return;
  for (const [id, show, value] of [
    ["system", showSystem, state.system],
    ["services", showServices, state.services],
    ["ports", showPorts, state.ports],
  ]) {
    try {
      show(value);
    } catch (error) {
      $(id).replaceChildren(el("span", { className: "bad" }, `Unexpected data: ${message(error)}`));
    }
  }
}

let timer = null;
let loading = false;

// Reads /state once and schedules the next read while the page is visible.
async function refresh() {
  if (loading) return;
  clearTimeout(timer);
  timer = null;
  loading = true;
  try {
    state = await api("/state");
    $("error").hidden = true;
  } catch (error) {
    $("error").textContent = `Box API: ${message(error)}`;
    $("error").hidden = false;
  } finally {
    loading = false;
  }
  render();
  if (document.visibilityState === "visible") timer = setTimeout(refresh, INTERVAL);
}

// Reads the box address and shows the first state; the tests wait for it.
async function start() {
  const address = (await chrome.storage.local.get("denbox:address"))["denbox:address"];
  if (!address) {
    $("error").textContent = "No box address. Set one in the extension's settings.";
    $("error").hidden = false;
    return;
  }
  api = boxApi(address);
  $("restart-all").addEventListener("click", () => act("all", "/services/restart", { name: "all" }));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void refresh();
    else {
      clearTimeout(timer);
      timer = null;
    }
  });
  await refresh();
}
const ready = start();
