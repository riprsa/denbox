# The environment of tailscale.sh: two boxes made with mkBoxes from the kit
# at /srv/denbox, with as little on as possible. Each runs a page on
# 127.0.0.1:8000 and serves it to the tailnet on port 8080; the control
# server is the test's Headscale.
{
  inputs.denbox.url = "path:/srv/denbox";

  outputs = { denbox, ... }:
    let
      common = { pkgs, ... }: {
        denbox.tools.enable = false;
        denbox.api.enable = false;
        home.packages = [ pkgs.curl ];
        denbox.services.web = pkgs.writeShellScript "web" ''
          exec ${pkgs.busybox}/bin/httpd -f -p 127.0.0.1:8000 -h ${pkgs.writeTextDir "index.html" "served by the box\n"}
        '';
        denbox.tailscale = {
          enable = true;
          loginServer = "http://headscale:8080";
          serve.web = { port = 8080; https = false; to = "http://127.0.0.1:8000"; };
        };
      };
    in
    {
      legacyPackages = denbox.lib.mkBoxes {
        kernel = { imports = [ common ]; denbox.tailscale.hostname = "box-kernel"; };
        # Named after the box by default.
        userspace = { imports = [ common ]; denbox.tailscale.userspace = true; };
      };
    };
}
