# Browser parts: code the extension loads from denbox-api's /bundle.json.
# api.nix builds the bundle from them.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  script = types.submodule {
    options = {
      matches = mkOption {
        type = types.listOf types.str;
        description = "URL match patterns of the pages the script runs in.";
      };
      js = mkOption {
        type = types.path;
        description = "The content script.";
      };
    };
  };
  page = types.submodule {
    options = {
      html = mkOption { type = types.path; description = "The page's HTML."; };
      js = mkOption { type = types.path; description = "The page's script."; };
    };
  };
  part = types.submodule {
    options = {
      background = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Script that runs in the extension's background.";
      };
      content = mkOption {
        type = types.listOf script;
        default = [ ];
        description = "Content scripts.";
      };
      pages = mkOption {
        type = types.attrsOf page;
        default = { };
        description = "Extension pages, by name.";
      };
    };
  };
in
{
  # Each part has the shape of a bundle part (docs/design.md, Browser), with
  # file paths in place of text.
  options.denbox.browser.parts = mkOption {
    type = types.attrsOf part;
    default = { };
    description = "Browser parts served to the extension, by name.";
  };
}
