###############################################################################
## Copyright (C) 2023-2025 Analog Devices, Inc. All rights reserved.
### SPDX short identifier: ADIBSD
###############################################################################

set LVDS_CMOS_N $ad_project_params(LVDS_CMOS_N)
set DEVICE $ad_project_params(DEVICE)

add_files -norecurse -fileset sources_1 [file normalize [file join [file dirname [info script]] "Event_Capture.v"]]
add_files -norecurse -fileset sources_1 [file normalize [file join [file dirname [info script]] "Event_Capture_Accumulator.v"]]
add_files -norecurse -fileset sources_1 [file normalize [file join [file dirname [info script]] "Event_Capture_FSM.v"]]
add_files -norecurse -fileset sources_1 [file normalize [file join [file dirname [info script]] "Event_Capture_AXIL.v"]]
add_files -norecurse -fileset sources_1 [file normalize [file join [file dirname [info script]] "Event_Capture_Buffer.v"]]
add_files -norecurse -fileset sources_1 [file normalize [file join [file dirname [info script]] "Event_Capture_Detector.v"]]

# Hardcoded for AD4857: 16-bit data width, 8 channels
set data_width 16
set numb_of_ch 8


# ad4857 interface

if {$LVDS_CMOS_N == "0"} {
  create_bd_port -dir O scki
  create_bd_port -dir I scko
  create_bd_port -dir I adc_lane_0
  create_bd_port -dir I adc_lane_1
  create_bd_port -dir I adc_lane_2
  create_bd_port -dir I adc_lane_3
  create_bd_port -dir I adc_lane_4
  create_bd_port -dir I adc_lane_5
  create_bd_port -dir I adc_lane_6
  create_bd_port -dir I adc_lane_7
} else {
  create_bd_port -dir O scki_p
  create_bd_port -dir O scki_n
  create_bd_port -dir I scko_p
  create_bd_port -dir I scko_n
  create_bd_port -dir I sdo_p
  create_bd_port -dir I sdo_n
}

create_bd_port -dir I busy
create_bd_port -dir O cnv
create_bd_port -dir O lvds_cmos_n

create_bd_port -dir O system_cpu_clk

# adc clock generator (Bypassed for testing without AD4857 card)
ad_ip_instance axi_clkgen adc_clkgen
ad_ip_parameter adc_clkgen CONFIG.CLKIN_PERIOD 10
ad_ip_parameter adc_clkgen CONFIG.VCO_DIV 1
ad_ip_parameter adc_clkgen CONFIG.VCO_MUL 10
ad_ip_parameter adc_clkgen CONFIG.CLK0_DIV 10
ad_connect  sys_cpu_clk adc_clkgen/clk
# Reset generator (using sys_200m_clk for cardless testing)
ad_ip_instance proc_sys_reset adc_rstgen
ad_ip_parameter adc_rstgen CONFIG.C_EXT_RST_WIDTH 1
ad_connect  adc_rstgen/ext_reset_in sys_cpu_resetn
ad_connect  adc_rstgen/slowest_sync_clk sys_cpu_clk
ad_connect  adc_resetn adc_rstgen/peripheral_aresetn
ad_connect  adc_reset adc_rstgen/peripheral_reset

# Clock Routing (Using the guaranteed sys_cpu_clk for cardless testing)
# We use sys_cpu_clk because it is always active when Linux is running.
set adc_clk_src sys_cpu_clk
# adc(ad4857-dma) - Continuous IIO DMA
ad_ip_instance axi_dmac ad4857_dma
ad_ip_parameter ad4857_dma CONFIG.DMA_TYPE_SRC 2
ad_ip_parameter ad4857_dma CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_dma CONFIG.CYCLIC 0
ad_ip_parameter ad4857_dma CONFIG.SYNC_TRANSFER_START 1
ad_ip_parameter ad4857_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_dma CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_dma CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_dma CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_dma CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_dma/fifo_wr_clk


# adc(ad4857-event-dma-0) - Event/UIO DMA (Channel 0)
ad_ip_instance axi_dmac ad4857_event_dma_0
ad_ip_parameter ad4857_event_dma_0 CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma_0 CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma_0 CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma_0 CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma_0 CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma_0 CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma_0 CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma_0 CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma_0 CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma_0/s_axis_aclk

# adc(ad4857-event-dma) - Event/UIO DMA (Channel 1)
ad_ip_instance axi_dmac ad4857_event_dma
ad_ip_parameter ad4857_event_dma CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma/s_axis_aclk

# adc(ad4857-event-dma-2) - Event/UIO DMA (Channel 2)
ad_ip_instance axi_dmac ad4857_event_dma_2
ad_ip_parameter ad4857_event_dma_2 CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma_2 CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma_2 CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma_2 CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma_2 CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma_2 CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma_2 CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma_2 CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma_2 CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma_2/s_axis_aclk

# adc(ad4857-event-dma-3) - Event/UIO DMA (Channel 3)
ad_ip_instance axi_dmac ad4857_event_dma_3
ad_ip_parameter ad4857_event_dma_3 CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma_3 CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma_3 CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma_3 CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma_3 CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma_3 CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma_3 CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma_3 CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma_3 CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma_3/s_axis_aclk

# adc(ad4857-event-dma-4) - Event/UIO DMA (Channel 4)
ad_ip_instance axi_dmac ad4857_event_dma_4
ad_ip_parameter ad4857_event_dma_4 CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma_4 CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma_4 CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma_4 CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma_4 CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma_4 CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma_4 CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma_4 CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma_4 CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma_4/s_axis_aclk

# adc(ad4857-event-dma-5) - Event/UIO DMA (Channel 5)
ad_ip_instance axi_dmac ad4857_event_dma_5
ad_ip_parameter ad4857_event_dma_5 CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma_5 CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma_5 CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma_5 CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma_5 CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma_5 CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma_5 CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma_5 CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma_5 CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma_5/s_axis_aclk

# adc(ad4857-event-dma-6) - Event/UIO DMA (Channel 6)
ad_ip_instance axi_dmac ad4857_event_dma_6
ad_ip_parameter ad4857_event_dma_6 CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma_6 CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma_6 CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma_6 CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma_6 CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma_6 CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma_6 CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma_6 CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma_6 CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma_6/s_axis_aclk

# adc(ad4857-event-dma-7) - Event/UIO DMA (Channel 7)
ad_ip_instance axi_dmac ad4857_event_dma_7
ad_ip_parameter ad4857_event_dma_7 CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter ad4857_event_dma_7 CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter ad4857_event_dma_7 CONFIG.CYCLIC 0
ad_ip_parameter ad4857_event_dma_7 CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter ad4857_event_dma_7 CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter ad4857_event_dma_7 CONFIG.AXI_SLICE_DEST 0
ad_ip_parameter ad4857_event_dma_7 CONFIG.DMA_2D_TRANSFER 0
ad_ip_parameter ad4857_event_dma_7 CONFIG.DMA_DATA_WIDTH_SRC $data_width
ad_ip_parameter ad4857_event_dma_7 CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk ad4857_event_dma_7/s_axis_aclk

# axi pwm gen

ad_ip_instance axi_pwm_gen axi_pwm_gen
ad_ip_parameter axi_pwm_gen CONFIG.N_PWMS 1
ad_ip_parameter axi_pwm_gen CONFIG.PULSE_0_WIDTH 1
ad_ip_parameter axi_pwm_gen CONFIG.PULSE_0_PERIOD 8

ad_connect cnv              axi_pwm_gen/pwm_0
ad_connect sys_cpu_clk      axi_pwm_gen/ext_clk
ad_connect sys_cpu_resetn   axi_pwm_gen/s_axi_aresetn
ad_connect sys_cpu_clk      axi_pwm_gen/s_axi_aclk

# axi_ad4857

ad_ip_instance axi_ad4857 axi_ad4857
ad_ip_parameter axi_ad4857 CONFIG.LVDS_CMOS_N $LVDS_CMOS_N
ad_ip_parameter axi_ad4857 CONFIG.EXTERNAL_CLK 1
ad_ip_parameter axi_ad4857 CONFIG.DEVICE $DEVICE
ad_connect  axi_ad4857/external_clk sys_cpu_clk
# AD4857: 8-lane interface connections
if {$LVDS_CMOS_N == "0"} {
  # CMOS mode: 8 lanes
  ad_connect  adc_lane_0  axi_ad4857/lane_0
  ad_connect  adc_lane_1  axi_ad4857/lane_1
  ad_connect  adc_lane_2  axi_ad4857/lane_2
  ad_connect  adc_lane_3  axi_ad4857/lane_3
  ad_connect  adc_lane_4  axi_ad4857/lane_4
  ad_connect  adc_lane_5  axi_ad4857/lane_5
  ad_connect  adc_lane_6  axi_ad4857/lane_6
  ad_connect  adc_lane_7  axi_ad4857/lane_7
  ad_connect  scko  axi_ad4857/scko
  ad_connect  scki  axi_ad4857/scki

} else {
  # LVDS mode
  ad_connect  axi_ad4857/external_fast_clk adc_fast_clk
  ad_connect  sdo_p   axi_ad4857/sdo_p
  ad_connect  sdo_n   axi_ad4857/sdo_n
  ad_connect  scko_p  axi_ad4857/scko_p
  ad_connect  scko_n  axi_ad4857/scko_n
  ad_connect  scki_p  axi_ad4857/scki_p
  ad_connect  scki_n  axi_ad4857/scki_n
}

ad_connect  busy  axi_ad4857/busy
ad_connect  lvds_cmos_n  axi_ad4857/lvds_cmos_n

# adc-path channel pack - Chain 0
ad_ip_instance util_cpack2 ad4857_adc_pack [list \
  NUM_OF_CHANNELS 1 \
  SAMPLE_DATA_WIDTH $data_width \
]
ad_connect sys_cpu_clk ad4857_adc_pack/clk
ad_connect adc_reset ad4857_adc_pack/reset
ad_connect axi_ad4857/adc_valid ad4857_adc_pack/fifo_wr_en
ad_connect ad4857_adc_pack/packed_fifo_wr ad4857_dma/fifo_wr
ad_connect ad4857_adc_pack/packed_sync ad4857_dma/sync
ad_connect axi_ad4857/adc_data_0 ad4857_adc_pack/fifo_wr_data_0
ad_connect axi_ad4857/adc_enable_0 ad4857_adc_pack/enable_0

# Merge overflows
ad_connect ad4857_adc_pack/fifo_wr_overflow axi_ad4857/adc_dovf

# Event Capture Pipeline 0 (Channel 0 -> DMA 0)

set event_capture_0 [create_bd_cell -type module -reference Event_Capture event_capture_0]

ad_connect sys_cpu_clk $event_capture_0/clk
ad_connect adc_reset   $event_capture_0/rst

# Input side: real ADC stream from axi_ad4857 channel 0
ad_connect axi_ad4857/adc_valid   $event_capture_0/s_axis_tvalid
ad_connect axi_ad4857/adc_data_0  $event_capture_0/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture_0/m_axis_tdata   ad4857_event_dma_0/s_axis_data
ad_connect $event_capture_0/m_axis_tvalid  ad4857_event_dma_0/s_axis_valid
ad_connect $event_capture_0/m_axis_tlast   ad4857_event_dma_0/s_axis_last
ad_connect $event_capture_0/m_axis_tready  ad4857_event_dma_0/s_axis_ready

# Event Capture Pipeline 1 (Channel 1 -> DMA 1)

set event_capture [create_bd_cell -type module -reference Event_Capture event_capture_1]

ad_connect sys_cpu_clk $event_capture/clk
ad_connect adc_reset   $event_capture/rst

# Input side: real ADC stream from axi_ad4857 channel 1
ad_connect axi_ad4857/adc_valid   $event_capture/s_axis_tvalid
ad_connect axi_ad4857/adc_data_1  $event_capture/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture/m_axis_tdata   ad4857_event_dma/s_axis_data
ad_connect $event_capture/m_axis_tvalid  ad4857_event_dma/s_axis_valid
ad_connect $event_capture/m_axis_tlast   ad4857_event_dma/s_axis_last
ad_connect $event_capture/m_axis_tready  ad4857_event_dma/s_axis_ready

# Event Capture Pipeline 2 (Channel 2 -> DMA 2)

set event_capture_2 [create_bd_cell -type module -reference Event_Capture event_capture_2]

ad_connect sys_cpu_clk $event_capture_2/clk
ad_connect adc_reset   $event_capture_2/rst

# Input side: real ADC stream from axi_ad4857 channel 2
ad_connect axi_ad4857/adc_valid   $event_capture_2/s_axis_tvalid
ad_connect axi_ad4857/adc_data_2  $event_capture_2/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture_2/m_axis_tdata   ad4857_event_dma_2/s_axis_data
ad_connect $event_capture_2/m_axis_tvalid  ad4857_event_dma_2/s_axis_valid
ad_connect $event_capture_2/m_axis_tlast   ad4857_event_dma_2/s_axis_last
ad_connect $event_capture_2/m_axis_tready  ad4857_event_dma_2/s_axis_ready

# Event Capture Pipeline 3 (Channel 3 -> DMA 3)

set event_capture_3 [create_bd_cell -type module -reference Event_Capture event_capture_3]

ad_connect sys_cpu_clk $event_capture_3/clk
ad_connect adc_reset   $event_capture_3/rst

# Input side: real ADC stream from axi_ad4857 channel 3
ad_connect axi_ad4857/adc_valid   $event_capture_3/s_axis_tvalid
ad_connect axi_ad4857/adc_data_3  $event_capture_3/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture_3/m_axis_tdata   ad4857_event_dma_3/s_axis_data
ad_connect $event_capture_3/m_axis_tvalid  ad4857_event_dma_3/s_axis_valid
ad_connect $event_capture_3/m_axis_tlast   ad4857_event_dma_3/s_axis_last
ad_connect $event_capture_3/m_axis_tready  ad4857_event_dma_3/s_axis_ready

# Event Capture Pipeline 4 (Channel 4 -> DMA 4)

set event_capture_4 [create_bd_cell -type module -reference Event_Capture event_capture_4]

ad_connect sys_cpu_clk $event_capture_4/clk
ad_connect adc_reset   $event_capture_4/rst

# Input side: real ADC stream from axi_ad4857 channel 4
ad_connect axi_ad4857/adc_valid   $event_capture_4/s_axis_tvalid
ad_connect axi_ad4857/adc_data_4  $event_capture_4/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture_4/m_axis_tdata   ad4857_event_dma_4/s_axis_data
ad_connect $event_capture_4/m_axis_tvalid  ad4857_event_dma_4/s_axis_valid
ad_connect $event_capture_4/m_axis_tlast   ad4857_event_dma_4/s_axis_last
ad_connect $event_capture_4/m_axis_tready  ad4857_event_dma_4/s_axis_ready

# Event Capture Pipeline 5 (Channel 5 -> DMA 5)

set event_capture_5 [create_bd_cell -type module -reference Event_Capture event_capture_5]

ad_connect sys_cpu_clk $event_capture_5/clk
ad_connect adc_reset   $event_capture_5/rst

# Input side: real ADC stream from axi_ad4857 channel 5
ad_connect axi_ad4857/adc_valid   $event_capture_5/s_axis_tvalid
ad_connect axi_ad4857/adc_data_5  $event_capture_5/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture_5/m_axis_tdata   ad4857_event_dma_5/s_axis_data
ad_connect $event_capture_5/m_axis_tvalid  ad4857_event_dma_5/s_axis_valid
ad_connect $event_capture_5/m_axis_tlast   ad4857_event_dma_5/s_axis_last
ad_connect $event_capture_5/m_axis_tready  ad4857_event_dma_5/s_axis_ready

# Event Capture Pipeline 6 (Channel 6 -> DMA 6)

set event_capture_6 [create_bd_cell -type module -reference Event_Capture event_capture_6]

ad_connect sys_cpu_clk $event_capture_6/clk
ad_connect adc_reset   $event_capture_6/rst

# Input side: real ADC stream from axi_ad4857 channel 6
ad_connect axi_ad4857/adc_valid   $event_capture_6/s_axis_tvalid
ad_connect axi_ad4857/adc_data_6  $event_capture_6/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture_6/m_axis_tdata   ad4857_event_dma_6/s_axis_data
ad_connect $event_capture_6/m_axis_tvalid  ad4857_event_dma_6/s_axis_valid
ad_connect $event_capture_6/m_axis_tlast   ad4857_event_dma_6/s_axis_last
ad_connect $event_capture_6/m_axis_tready  ad4857_event_dma_6/s_axis_ready

# Event Capture Pipeline 7 (Channel 7 -> DMA 7)

set event_capture_7 [create_bd_cell -type module -reference Event_Capture event_capture_7]

ad_connect sys_cpu_clk $event_capture_7/clk
ad_connect adc_reset   $event_capture_7/rst

# Input side: real ADC stream from axi_ad4857 channel 7
ad_connect axi_ad4857/adc_valid   $event_capture_7/s_axis_tvalid
ad_connect axi_ad4857/adc_data_7  $event_capture_7/s_axis_tdata

# Output side (Master AXI-Stream)
ad_connect $event_capture_7/m_axis_tdata   ad4857_event_dma_7/s_axis_data
ad_connect $event_capture_7/m_axis_tvalid  ad4857_event_dma_7/s_axis_valid
ad_connect $event_capture_7/m_axis_tlast   ad4857_event_dma_7/s_axis_last
ad_connect $event_capture_7/m_axis_tready  ad4857_event_dma_7/s_axis_ready

# Sync/Control signals (Triggered by AXI-Stream Valid)

ad_connect  sys_cpu_clk         system_cpu_clk

ad_connect  sys_200m_clk       axi_ad4857/delay_clk
ad_connect  axi_pwm_gen/pwm_0   axi_ad4857/cnvs

# interrupts

ad_cpu_interrupt ps-7  mb-7   ad4857_dma/irq
ad_cpu_interrupt ps-10 mb-10  ad4857_event_dma_0/irq
ad_cpu_interrupt ps-11 mb-11  ad4857_event_dma/irq
ad_cpu_interrupt ps-12 mb-12  ad4857_event_dma_2/irq
ad_cpu_interrupt ps-13 mb-13  ad4857_event_dma_3/irq
ad_cpu_interrupt ps-14 mb-14  ad4857_event_dma_4/irq
ad_cpu_interrupt ps-15 mb-15  ad4857_event_dma_5/irq
ad_cpu_interrupt ps-9  mb-9   ad4857_event_dma_6/irq
ad_cpu_interrupt ps-8  mb-8   ad4857_event_dma_7/irq

# cpu / memory interconnects

ad_cpu_interconnect 0x43c00000 axi_ad4857
ad_cpu_interconnect 0x43d00000 axi_pwm_gen
ad_cpu_interconnect 0x43e00000 ad4857_event_dma_0
ad_cpu_interconnect 0x43f00000 ad4857_event_dma
ad_cpu_interconnect 0x44000000 adc_clkgen
ad_cpu_interconnect 0x44100000 ad4857_event_dma_2
ad_cpu_interconnect 0x44200000 $event_capture
ad_cpu_interconnect 0x44300000 $event_capture_2
ad_cpu_interconnect 0x44400000 ad4857_event_dma_3
ad_cpu_interconnect 0x44500000 $event_capture_3
ad_cpu_interconnect 0x44600000 ad4857_event_dma_4
ad_cpu_interconnect 0x44700000 $event_capture_4
ad_cpu_interconnect 0x44800000 ad4857_event_dma_5
ad_cpu_interconnect 0x44900000 $event_capture_5
ad_cpu_interconnect 0x44a00000 ad4857_event_dma_6
ad_cpu_interconnect 0x44b00000 $event_capture_6
ad_cpu_interconnect 0x44c00000 ad4857_event_dma_7
ad_cpu_interconnect 0x44d00000 $event_capture_7
ad_cpu_interconnect 0x44e00000 $event_capture_0
ad_cpu_interconnect 0x44f00000 ad4857_dma

ad_mem_hp1_interconnect sys_cpu_clk    sys_ps7/S_AXI_HP1
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_dma/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma_0/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma_2/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma_3/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma_4/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma_5/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma_6/m_dest_axi
ad_mem_hp1_interconnect $sys_dma_clk   ad4857_event_dma_7/m_dest_axi

ad_connect $sys_dma_resetn             ad4857_dma/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma_0/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma_2/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma_3/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma_4/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma_5/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma_6/m_dest_axi_aresetn
ad_connect $sys_dma_resetn             ad4857_event_dma_7/m_dest_axi_aresetn
