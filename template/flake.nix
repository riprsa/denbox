{
  description = "My denbox environment";

  inputs.denbox.url = "github:riprsa/denbox";

  outputs = { denbox, ... }: {
    # One attribute per box; `nix build .#boxes.main` builds this one.
    legacyPackages = denbox.lib.mkBoxes {
      main = { pkgs, ... }: {
        # The standard Docker deployment publishes this port on the host's
        # loopback, so the API listens on every interface of the container.
        # On a host without a container the default 127.0.0.1:48099 suits.
        denbox.api.address = "0.0.0.0:48099";

        # T3 Code on port 3773, projects in ~/Projects.
        denbox.t3.enable = true;
        # denbox.t3.settings = { };   # merged into T3's settings.json

        # Coding agents, with the same instructions and skills for each.
        denbox.agents.claude.enable = true;
        denbox.agents.codex.enable = true;
        denbox.agents.instructions = ./agent/AGENTS.md;
        # denbox.agents.skills = ./agent/skills;   # one directory per skill
        # denbox.agents.mcpServers.docs.url = "https://mcp.example.com/mcp";

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
