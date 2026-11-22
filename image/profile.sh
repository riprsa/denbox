# Debian's /etc/profile resets PATH for login shells. Put the box's profile
# and Nix back in front, so a terminal finds what the services find.
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/gcroots/denbox-nix/bin:/usr/local/bin:$PATH"
