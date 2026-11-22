# Claude Code and Codex: the commands on PATH, started through the secrets
# provider with consumer agents, and configuration merged into what each
# agent reads. The kit does not model either agent's configuration, and it
# writes no instructions or skills; those are the environment's own files.
{ config, lib, pkgs, kit, ... }:
let
  cfg = config.denbox.agents;
  inherit (lib) mkOption types;
  inherit (config.denbox.secrets) provider;
  json = pkgs.formats.json { };
  toml = pkgs.formats.toml { };

  # A TOML inline value; JSON string escapes are valid TOML.
  tomlValue = v:
    if builtins.isAttrs v then "{" + lib.concatStringsSep ", " (lib.mapAttrsToList (k: x: "${builtins.toJSON k} = ${tomlValue x}") v) + "}"
    else if builtins.isList v then "[" + lib.concatMapStringsSep ", " tomlValue v + "]"
    else builtins.toJSON v;
  # One `path=value` per leaf of codex.config; a list is a leaf. Codex splits
  # the path at every dot and takes each part literally, quotes included, so
  # a key is passed as it is and one Codex cannot address is refused.
  leaves = path: v:
    if builtins.isAttrs v then lib.concatLists (lib.mapAttrsToList (k: x:
      lib.throwIf (k == "" || lib.hasInfix "." k || lib.hasInfix "=" k)
        "denbox.agents.codex.config: Codex cannot address the key \"${k}\" with -c"
        (leaves (path ++ [ k ]) x)) v)
    else [ "${lib.concatStringsSep "." path}=${tomlValue v}" ];
  # Before the user's arguments, so a -c of the user's wins, and per leaf, so
  # a table in ~/.codex/config.toml keeps its other keys.
  codexFlags = lib.concatMapStringsSep " " (o: "-c ${lib.escapeShellArg o}") (leaves [ ] cfg.codex.config);

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

  # mergeClaudeServers FILE: merges claude.mcpServers recursively into
  # .mcpServers of FILE, so servers and keys set by hand stay. Claude reads
  # user-scope servers only from the mutable ~/.claude.json.
  mergeClaudeServers = pkgs.writeShellScript "denbox-claude-mcp-servers" ''
    set -euo pipefail
    file=$1
    [[ -s $file ]] || (umask 077; echo '{}' > "$file")
    new=$(mktemp "$file.XXXXXX")
    if ${lib.getExe pkgs.jq} --slurpfile ours ${json.generate "claude-mcp-servers.json" cfg.claude.mcpServers} \
      '.mcpServers = ((.mcpServers // {}) * $ours[0])' "$file" > "$new"; then
      chmod 0600 "$new"
      mv -f "$new" "$file"
    else
      rm -f "$new"
      exit 1
    fi
  '';

  # enable and package of the agent `name`, packaged as kit.${attr}.
  agentOptions = name: attr: {
    enable = lib.mkEnableOption name;
    package = mkOption {
      type = types.package;
      default = kit.${attr};
      defaultText = lib.literalExpression "kit.${attr}";
      description = "The ${name} package; override to wrap, patch or repin.";
    };
  };
in
{
  options.denbox.agents = {
    claude = agentOptions "Claude Code" "claude" // {
      # Any key Claude understands, alwaysLoad and headers included.
      mcpServers = mkOption {
        type = types.attrsOf json.type;
        default = { };
        example = { docs = { type = "http"; url = "https://mcp.example.com/mcp"; }; };
        description = "Merged recursively into .mcpServers of ~/.claude.json on activation.";
      };
    };
    codex = agentOptions "Codex" "codex" // {
      # Any key Codex understands; see the comment of `leaves` above.
      config = mkOption {
        type = types.attrsOf toml.type;
        default = { };
        example = { mcp_servers.docs.url = "https://mcp.example.com/mcp"; };
        description = "Codex configuration, passed as one `-c dotted.path=value` override per leaf value.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.claude.enable {
      home.packages = [ claude ];
      # A broken file must not block the rest of the activation.
      home.activation.denboxClaudeMcpServers = lib.mkIf (cfg.claude.mcpServers != { }) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if [[ ! -v DRY_RUN ]]; then
          ${mergeClaudeServers} "$HOME/.claude.json" || warnEcho "Could not merge MCP servers into $HOME/.claude.json"
        fi
      '');
    })
    (lib.mkIf cfg.codex.enable {
      home.packages = [ codex ];
    })
  ];
}
