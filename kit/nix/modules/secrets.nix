# The secrets provider. Every kit service that needs secrets starts its
# command as `PROVIDER CONSUMER -- COMMAND [ARGS...]`, with the consumers
# shell, agents and t3 (docs/design.md, Secrets).
{ lib, pkgs, ... }:
let
  # Adds nothing: drops the consumer and the separator, then execs the command.
  passthrough = pkgs.writeShellScript "denbox-secrets-passthrough" ''
    if [[ $# -lt 2 || $2 != -- ]]; then
      echo "usage: $0 CONSUMER -- COMMAND [ARGS...]" >&2
      exit 2
    fi
    shift 2
    exec "$@"
  '';
in
{
  options.denbox.secrets.provider = lib.mkOption {
    type = lib.types.path;
    default = passthrough;
    defaultText = lib.literalMD "a passthrough that adds no variables";
    description = "Executable called as `PROVIDER CONSUMER -- COMMAND [ARGS...]`; it execs COMMAND with the variables meant for CONSUMER.";
  };
}
