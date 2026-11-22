// The kit's panel part is embedded into the bundle as text, with no build that
// would catch a syntax error; compile it here the way page.js runs it.
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const { compile } = require("../bundle.js");

test("the panel's page code compiles", () => {
  const code = readFileSync(path.join(__dirname, "../../kit/browser/panel/panel.js"), "utf8");
  assert.doesNotThrow(() => compile(code));
});
