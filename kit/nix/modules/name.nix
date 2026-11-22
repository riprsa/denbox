# The box's name. mkBoxes sets it to the box's attribute name; anything in
# the kit that needs a name for the box reads it from here.
{ lib, ... }:
{
  options.denbox.name = lib.mkOption {
    type = lib.types.strMatching "^[A-Za-z0-9_-]+$";
    example = "personal";
    description = "The box's name, set by mkBoxes to the box's attribute name.";
  };
}
