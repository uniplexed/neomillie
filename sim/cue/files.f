# The cue bench: cd_mount with cd_host, core_bridge_cmd.v and the host's side of target commands.
# cdd_drive.sv first: it holds the package of cd_defs.svh
+incdir+rtl/cd
rtl/cd/cdd_drive.sv
sim/apf/bridge_bfm.sv
sim/cd/host_bfm.sv
upstream/core-template/src/fpga/apf/common.v
upstream/core-template/src/fpga/apf/mf_datatable.v
upstream/core-template/src/fpga/core/core_bridge_cmd.v
sim/models/altera_stubs.sv
rtl/cd/cd_host.sv
rtl/cd/cd_mount.sv
