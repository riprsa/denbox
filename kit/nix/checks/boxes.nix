# Builds boxes through lib.mkBoxes: one with everything off, one with T3 and
# both agents on, and the template's box evaluated against this checkout of
# the kit. Checks the files the full box puts in place.
{ system, kit, runCommand, writeText, writeTextDir }:
let
  boxes = (kit.lib.mkBoxes {
    off = {
      denbox.tools.enable = false;
      denbox.api.enable = false;
    };
    full = {
      denbox.t3.enable = true;
      denbox.t3.settings.example = true;
      denbox.agents.claude.enable = true;
      denbox.agents.codex.enable = true;
      denbox.agents.instructions = writeText "AGENTS.md" "Be brief.";
      denbox.agents.extraInstructions = "Use example.com.";
      denbox.agents.skills = writeTextDir "greet/SKILL.md" "greet";
      denbox.agents.mcpServers.docs.url = "https://mcp.example.com/mcp";
      denbox.follow.denbox = "github:riprsa/denbox";
    };
  }).${system}.boxes;
  inherit (boxes) off full;
  template = ((import ../../../template/flake.nix).outputs { denbox = kit; }).legacyPackages.${system}.boxes.main;
  inherit (full.config.denbox) services;
in
assert off.follow == { };
assert full.follow == { denbox = "github:riprsa/denbox"; };
runCommand "denbox-boxes-check" { } ''
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

  for f in .claude/CLAUDE.md .codex/AGENTS.md; do
    [[ $(< "$files/$f") == $'Be brief.\nUse example.com.' ]] || fail "$f: unexpected instructions"
  done
  for d in .claude/skills .agents/skills; do
    [[ -e $files/$d/greet/SKILL.md ]] || fail "$d: skill missing"
  done

  # Both commands go through the provider with consumer agents; Codex gets
  # the MCP server as an override, Claude at activation.
  grep -q ' agents -- ' "$bin/claude" && grep -q ' agents -- ' "$bin/codex" || fail "agents: no provider"
  grep -q 'mcp_servers.docs={.*"url" = "https://mcp.example.com/mcp"}' "$bin/codex" || fail "codex: no MCP server"
  grep -q 'mcp.example.com' ${full}/activate || fail "claude: no MCP server"

  [[ -e ${template}/activate ]] || fail "template: no activation"
  touch "$out"
''
