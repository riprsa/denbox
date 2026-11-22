# Builds boxes through lib.mkBoxes: one with everything off, one with T3 and
# both agents on, and the template's box evaluated against this checkout of
# the kit. Checks the files the full box puts in place, the Codex flags, the
# Claude merge and the module argument kit.
{ system, kit, lib, runCommand, jq }:
let
  boxes = (kit.lib.mkBoxes {
    off = {
      denbox.tools.enable = false;
      denbox.api.enable = false;
    };
    full = { kit, pkgs, ... }: {
      denbox.t3.enable = true;
      denbox.t3.settings.example = true;
      denbox.agents.claude.enable = true;
      denbox.agents.claude.mcpServers.docs = { url = "https://mcp.example.com/mcp"; alwaysLoad = true; };
      # Wrapped through the module argument, as an environment would.
      denbox.agents.codex.package = pkgs.writeShellScriptBin "codex" ''exec ${lib.getExe kit.codex} "$@"'';
      denbox.agents.codex.enable = true;
      denbox.agents.codex.config = {
        model = "o3";
        mcp_servers.docs = {
          url = "https://mcp.example.com/mcp";
          env_http_headers.X-Thread = "THREAD_ID";
          args = [ "--x" { a = 1; } ];
        };
        mcp_servers."my docs".enabled = false;
      };
      denbox.follow.denbox = "github:riprsa/denbox";
    };
  }).${system}.boxes;
  inherit (boxes) off full;
  template = ((import ../../../template/flake.nix).outputs { denbox = kit; }).legacyPackages.${system}.boxes.main;
  inherit (full.config.denbox) services agents;
  # The flags codex gets, one per leaf, sorted by path, before the user's arguments.
  codexFlags = ''-c 'mcp_servers.docs.args=["--x", {"a" = 1}]' -c 'mcp_servers.docs.env_http_headers.X-Thread="THREAD_ID"' -c 'mcp_servers.docs.url="https://mcp.example.com/mcp"' -c 'mcp_servers.my docs.enabled=false' -c 'model="o3"' "$@"'';
  # A hand-added server and a neighbouring key, both of which the merge keeps.
  claudeBefore = builtins.toJSON {
    numStartups = 3;
    mcpServers = {
      mine = { command = "mine"; };
      docs = { type = "http"; url = "https://old.example.com/mcp"; headers.X = "1"; };
    };
  };
  claudeAfter = builtins.toJSON {
    numStartups = 3;
    mcpServers = {
      mine = { command = "mine"; };
      docs = { type = "http"; url = "https://mcp.example.com/mcp"; headers.X = "1"; alwaysLoad = true; };
    };
  };
in
assert off.follow == { };
assert full.follow == { denbox = "github:riprsa/denbox"; };
# The kit's defaults are its packages.
assert agents.claude.package.drvPath == kit.packages.${system}.claude.drvPath;
runCommand "denbox-boxes-check" { nativeBuildInputs = [ jq ]; } ''
  fail() { echo "$*" >&2; exit 1; }

  # Everything off: no services, no shell hook.
  [[ ! -e ${off}/home-files/.config/denbox ]] || fail "off: denbox files present"

  files=${full}/home-files
  bin=${full}/home-path/bin
  [[ $(readlink "$files/.config/denbox/services/t3/run") == ${services.t3} ]] || fail "t3: wrong run link"
  grep -q ' t3 -- .*/bin/t3 serve' ${services.t3} || fail "t3: not started through the provider"
  grep -q '"example": *true' $(grep -o '/nix/store/[^ ]*-t3-settings.json' ${services.t3}) \
    || fail "t3: settings not merged"

  [[ -x $files/.config/denbox/shell ]] && grep -q ' shell -- .*/bin/fish' "$files/.config/denbox/shell" \
    || fail "shell: hook missing"

  # The kit writes no instructions or skills.
  for f in .claude .codex .agents; do [[ ! -e $files/$f ]] || fail "$f: written by the kit"; done

  # Both commands go through the provider with consumer agents.
  grep -q ' agents -- ' "$bin/claude" && grep -q ' agents -- ' "$bin/codex" || fail "agents: no provider"
  # The module argument kit.codex is the kit's package.
  grep -qF ${kit.packages.${system}.codex}/bin/codex ${agents.codex.package}/bin/codex || fail "kit.codex: not the kit's"
  grep -qF -e ${lib.escapeShellArg codexFlags} "$bin/codex" || fail "codex: unexpected flags: $(grep agents "$bin/codex")"

  # The Claude merge keeps what it does not set.
  merge=$(grep -o '/nix/store/[^ ]*-denbox-claude-mcp-servers' ${full}/activate)
  echo ${lib.escapeShellArg claudeBefore} > claude.json
  "$merge" claude.json
  jq -e --argjson expected ${lib.escapeShellArg claudeAfter} '. == $expected' claude.json > /dev/null \
    || fail "claude: unexpected merge: $(cat claude.json)"
  rm claude.json
  "$merge" claude.json
  jq -e '.mcpServers.docs.alwaysLoad' claude.json > /dev/null || fail "claude: no file created"

  [[ -e ${template}/activate ]] || fail "template: no activation"
  [[ -e ${template}/home-files/.claude/CLAUDE.md && -e ${template}/home-files/.codex/AGENTS.md ]] \
    || fail "template: no instructions"
  touch "$out"
''
