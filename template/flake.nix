{
  description = "My denbox environment";

  inputs.denbox.url = "github:riprsa/denbox";

  outputs = { denbox, ... }: {
    # One attribute per box; `nix build .#boxes.main` builds this one.
    legacyPackages = denbox.lib.mkBoxes {
      # kit holds the kit's packages (kit.claude, kit.codex, kit.t3, ...).
      main = { pkgs, lib, kit, ... }: {
        # The standard Docker deployment publishes this port on the host's
        # loopback, so the API listens on every interface of the container.
        # On a host without a container the default 127.0.0.1:48099 suits.
        denbox.api.address = "0.0.0.0:48099";

        # T3 Code on port 3773, projects in ~/Projects.
        denbox.t3.enable = true;
        # denbox.t3.settings = { };   # merged into T3's settings.json

        # Claude Code, with its instructions and skills as files of this flake.
        denbox.agents.claude.enable = true;
        home.file.".claude/CLAUDE.md".source = ./agent/AGENTS.md;
        # Recursive, so the agent can add skills of its own next to these.
        # home.file.".claude/skills" = { source = ./agent/skills; recursive = true; };
        # Merged into .mcpServers of ~/.claude.json; any key Claude reads.
        # denbox.agents.claude.mcpServers.docs = { type = "http"; url = "https://mcp.example.com/mcp"; };
        # The agent wrapped, here to reach it through a proxy.
        # denbox.agents.claude.package = pkgs.writeShellScriptBin "claude" ''
        #   export ANTHROPIC_BASE_URL=https://proxy.example.com
        #   exec ${lib.getExe kit.claude} "$@"
        # '';

        # Codex, the same way.
        denbox.agents.codex.enable = true;
        home.file.".codex/AGENTS.md".source = ./agent/AGENTS.md;
        # home.file.".agents/skills" = { source = ./agent/skills; recursive = true; };
        # One `-c` override per value; ~/.codex/config.toml keeps the rest.
        # denbox.agents.codex.config.mcp_servers.docs.url = "https://mcp.example.com/mcp";

        # A program that execs a command with secrets, called as
        # `PROVIDER CONSUMER -- COMMAND [ARGS...]`; the default adds none.
        # denbox.secrets.provider = ./secrets.sh;

        # Build against the kit's current main at every sync instead of
        # waiting for this flake's lock to move.
        # denbox.follow.denbox = "github:riprsa/denbox";

        # Anything else Home Manager can do.
        home.packages = [ pkgs.htop ];
      };
    };
  };
}
