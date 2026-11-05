# The cd bench: cd_host against core_bridge_cmd.v and the host's side of target commands (with the wait
# counter's slot write, which only that build has), and cd_fetch streaming into MiSTer's cd_sys
+define+NEOGEO_WAIT_COUNTER=1
-Wno-PROCASSWIRE
+incdir+rtl/cd
sim/apf/bridge_bfm.sv
sim/cd/host_bfm.sv
upstream/core-template/src/fpga/apf/common.v
upstream/core-template/src/fpga/apf/mf_datatable.v
upstream/core-template/src/fpga/core/core_bridge_cmd.v
sim/models/altera_stubs.sv
upstream/NeoGeo_MiSTer/rtl/mem/dpram.v
rtl/cd/cd.sv
upstream/NeoGeo_MiSTer/rtl/cd/drive.v
rtl/cd/lc8951.v
upstream/NeoGeo_MiSTer/rtl/cd/cdda.v
rtl/cd/cd_host.sv
rtl/cd/cd_fetch.sv
rtl/test/wait_counter.sv
