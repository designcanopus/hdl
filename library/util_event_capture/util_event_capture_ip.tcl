source ../../scripts/adi_env.tcl
source $ad_hdl_dir/library/scripts/adi_ip_xilinx.tcl

adi_ip_create util_event_capture
adi_ip_files util_event_capture [list \
  "util_event_capture.v" ]

adi_ip_properties_lite util_event_capture

ipx::save_core [ipx::current_core]
