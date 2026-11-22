# Claude Code and Codex: the commands on PATH, user-wide instructions, skills
# and MCP servers. Both commands start through the secrets provider with
# consumer agents.
{ config, lib, pkgs, ... }:
let
  cfg = config.denbox.agents;
  inherit (lib) mkOption types;
  inherit (config.denbox.secrets) provider;

  # One shape for both agents: a local command, or an HTTP endpoint.
  server = types.submodule {
    options = {
      command = mkOption { type = types.nullOr types.str; default = null; description = "Command of a stdio server."; };
      args = mkOption { type = types.listOf types.str; default = [ ]; description = "Its arguments."; };
      env = mkOption { type = types.attrsOf types.str; default = { }; description = "Its environment."; };
      url = mkOption { type = types.nullOr types.str; default = null; description = "URL of a streamable HTTP server."; };
      headers = mkOption { type = types.attrsOf types.str; default = { }; description = "HTTP headers sent to it."; };
    };
  };
  forClaude = s:
    if s.url != null then { type = "http"; inherit (s) url headers; }
    else { type = "stdio"; inherit (s) command args env; };
  forCodex = s:
    if s.url != null then { inherit (s) url; http_headers = s.headers; }
    else { inherit (s) command args env; };

  # A TOML inline value; JSON string escapes are valid TOML.
  toml = v:
    if builtins.isAttrs v then "{" + lib.concatStringsSep ", " (lib.mapAttrsToList (k: x: "${builtins.toJSON k} = ${toml x}") v) + "}"
    else if builtins.isList v then "[" + lib.concatMapStringsSep ", " toml v + "]"
    else builtins.toJSON v;
  # Codex gets the servers as -c overrides, so ~/.codex/config.toml stays
  # Codex's own, writable file. They come first: a -c of the user's wins.
  codexFlags = lib.concatStringsSep " " (lib.mapAttrsToList
    (name: s: "-c " + lib.escapeShellArg "mcp_servers.${name}=${toml (forCodex s)}") cfg.mcpServers);

  # Version and help probes run the agent directly, without the provider,
  # so they work without secrets or network.
  wrap = name: bin: launch: pkgs.writeShellScriptBin name ''
    case "''${1:-}" in
      --version|-v|-V|--help|-h|help|completion) exec ${bin} "$@" ;;
    esac
    ${launch}
  '';
  claude = wrap "claude" (lib.getExe cfg.claude.package) ''
    # A box runs as root; Claude allows bypassing permissions for root only
    # in an environment declared a sandbox, which a box is.
    export IS_SANDBOX=1
    exec ${provider} agents -- ${lib.getExe cfg.claude.package} "$@"
  '';
  codex = wrap "codex" (lib.getExe cfg.codex.package) ''
    exec ${provider} agents -- ${lib.getExe cfg.codex.package} ${codexFlags} "$@"
  '';

  # The instructions file, then the extra lines; built, so instructions may
  # also be a derivation.
  hasInstructions = cfg.instructions != null || cfg.extraInstructions != "";
  instructions = pkgs.runCommand "agent-instructions.md" { inherit (cfg) extraInstructions; } ''
    { ${lib.optionalString (cfg.instructions != null) "cat ${cfg.instructions}; echo"}
      printf '%s' "$extraInstructions"; } > "$out"
  '';
  # Recursive, so the directories stay writable for skills an agent adds itself.
  skills = lib.optionalAttrs (cfg.skills != null) { source = cfg.skills; recursive = true; };

  # Claude reads user-scope MCP servers only from the mutable ~/.claude.json,
  # so ours are merged in on every activation. A broken file must not block
  # the rest of the activation.
  claudeServers = builtins.toJSON (lib.mapAttrs (_: forClaude) cfg.mcpServers);
  claudeMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    claude_config="$HOME/.claude.json"
    if [[ ! -v DRY_RUN ]]; then
      [[ -s "$claude_config" ]] || (umask 077; echo '{}' > "$claude_config")
      claude_config_new="$(mktemp "$claude_config.XXXXXX")"
      if ${lib.getExe pkgs.jq} --argjson servers ${lib.escapeShellArg claudeServers} \
        '.mcpServers = ((.mcpServers // {}) + $servers)' "$claude_config" > "$claude_config_new"; then
        chmod 0600 "$claude_config_new"
        mv -f "$claude_config_new" "$claude_config"
      else
        rm -f "$claude_config_new"
        warnEcho "Could not register MCP servers in $claude_config"
      fi
    fi
  '';

  agentOptions = name: default: {
    enable = lib.mkEnableOption name;
    package = mkOption {
      type = types.package;
      inherit default;
      defaultText = lib.literalMD "the kit's pin in `kit/nix/packages`";
      description = "The ${name} package; override to wrap, patch or repin.";
    };
  };
in
{
  options.denbox.agents = {
    claude = agentOptions "Claude Code" (pkgs.callPackage ../packages/claude.nix { });
    codex = agentOptions "Codex" (pkgs.callPackage ../packages/codex.nix { });
    instructions = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Markdown file given to every enabled agent as its user-wide instructions.";
    };
    extraInstructions = mkOption {
      type = types.lines;
      default = "";
      description = "Lines appended to the instructions.";
    };
    skills = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Directory of skills, one subdirectory each, given to every enabled agent.";
    };
    mcpServers = mkOption {
      type = types.attrsOf server;
      default = { };
      example = { docs = { url = "https://mcp.example.com/mcp"; }; };
      description = "MCP servers registered with every enabled agent, by name.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList (name: s: {
        assertion = builtins.match "[A-Za-z0-9_-]+" name != null && (s.command == null) != (s.url == null);
        message = "denbox.agents.mcpServers.${name}: the name must be letters, digits, _ or -, and exactly one of command and url must be set.";
      }) cfg.mcpServers;
    }
    (lib.mkIf cfg.claude.enable {
      home.packages = [ claude ];
      home.file.".claude/CLAUDE.md" = lib.mkIf hasInstructions { source = instructions; };
      home.file.".claude/skills" = lib.mkIf (cfg.skills != null) skills;
      home.activation.denboxClaudeMcpServers = lib.mkIf (cfg.mcpServers != { }) claudeMcp;
    })
    (lib.mkIf cfg.codex.enable {
      home.packages = [ codex ];
      home.file.".codex/AGENTS.md" = lib.mkIf hasInstructions { source = instructions; };
      home.file.".agents/skills" = lib.mkIf (cfg.skills != null) skills;
    })
  ];
}
