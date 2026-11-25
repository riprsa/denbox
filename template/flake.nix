{
  description = "My denbox environment";

  inputs.denbox.url = "github:riprsa/denbox";

  outputs = { denbox, ... }: {
    # One attribute per box; `nix build .#boxes.main` builds this one.
    legacyPackages = denbox.lib.mkBoxes {
      # kit holds the kit's packages (kit.claude, kit.codex, kit.t3, ...).
      main = { pkgs, lib, kit, ... }: {
        # Listening beyond the box's loopback makes the box ask its host to
        # publish the port, on the host's loopback (denbox.host.ports.api).
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

        # The box as a node of a tailnet, with a name and an address of its
        # own. It asks its host for the tunnel device, NET_ADMIN and the key,
        # which install.sh shows and asks for. Tag the node and give the tag
        # only the access a box needs.
        # denbox.tailscale = {
        #   enable = true;
        #   tags = [ "tag:denbox" ];
        #   # T3 Code at https://<box>.<tailnet>.ts.net, denbox-api on its port 8443.
        #   serve.t3 = { port = 443; to = "http://127.0.0.1:3773"; };
        #   serve.api = { port = 8443; to = "http://127.0.0.1:48099"; };
        # };

        # What the box asks of its host beyond what modules declare; see
        # docs/design.md, What a box asks of its host. install.sh shows it
        # and starts the box only once you accept it.
        # denbox.host.ports.t3.hostPort = 13773;
        # denbox.host.memory = "8g";
        # denbox.host.secrets.api_key.description = "Key of the example API";

        # Build against the kit's current main at every sync instead of
        # waiting for this flake's lock to move.
        # denbox.follow.denbox = "github:riprsa/denbox";

        # Build a new commit and wait for `denbox apply` instead of activating it.
        # denbox.apply = "approve";

        # Anything else Home Manager can do.
        home.packages = [ pkgs.htop ];
      };
    };
  };
}
