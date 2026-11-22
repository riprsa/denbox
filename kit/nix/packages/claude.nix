# Claude Code: nixpkgs' package with the release pinned in claude-sources.json
# (moved by ./update-pins). Unfree; mkBoxes allows it by name.
{ claude-code, lib }:
claude-code.override { manifest = lib.importJSON ./claude-sources.json; }
