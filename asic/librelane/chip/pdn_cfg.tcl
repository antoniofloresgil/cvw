# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# PDN of the chips: sram/pdn_cfg.tcl, and Metal2 and Metal3 straps in the standard cell grid.
#
# IHP's precheck requires 25 % of each metal (with fill) in every 800 x 800 um window (MxFil.h).
# Routed Metal2 and Metal3 leave the centre of the core at 20-24 %, in gaps too narrow for 1 um
# fill squares; these straps add about 7 % of Metal2 and 5 % of Metal3, with the Magic filler
# (Metal2 straps 2 um wide left three windows at 23.6-23.9 %).
#
# The Metal2 straps (vertical, like Metal2 routing) lie in channels without cells (FP_OBSTRUCTIONS
# in gen_config.py, which must follow the offset and pitch here): over cells they covered pins,
# and the antenna repair after detailed routing could not insert its diodes next to them without
# shorts.  They are placed away from the TopMetal1 straps (2.2 um wide, pitch 75.6 um, offset
# 13.6 um, spacing 4 um), whose stacked vias down to the Metal1 rails cross Metal2 and Metal3.
# The Metal3 straps lie in the middle of a row (3.78 um high), away from the rails' vias, and
# connect to TopMetal1 as well, since the rails, and so the Metal2 straps' vias to them, may stop
# at the channels.  Offsets are to a strap's centre, from the first row.  pdngen also puts a strap
# pair in the middle of any region narrower than the pitch, which can land under a TopMetal1
# strap: gen_config.py places the SRAM macro in a corner of the core, so that it leaves no such strip.

source [file dirname [info script]]/../sram/pdn_cfg.tcl

add_pdn_stripe -grid stdcell_grid -layer Metal2 -width 2.8 -spacing 2.0 -pitch 75.6 -offset 51.0 \
    -starts_with POWER
add_pdn_stripe -grid stdcell_grid -layer Metal3 -width 1.0 -spacing 2.78 -pitch 37.8 -offset 1.89 \
    -starts_with POWER
add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_RAIL_LAYER) Metal2"
add_pdn_connect -grid stdcell_grid -layers "Metal2 Metal3"
add_pdn_connect -grid stdcell_grid -layers "Metal3 $::env(PDN_VERTICAL_LAYER)"
