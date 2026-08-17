# AD4857-FMCZ HDL Project

-- Evaluation board product page:
  - [EVAL-AD4857](https://www.analog.com/eval-ad4857)

- System documentation: https://wiki.analog.com/resources/eval/user-guides/ad4858_fmcz/ad4858_fmcz_hdl
- HDL project documentation: http://analogdevicesinc.github.io/hdl/projects/ad585x_fmcz/index.html
- Evaluation board VADJ range: 1.8V - 3.3V

:warning: Make sure the power supplies on the evaluation board are configured as expected, from jumper selection. In particular, pay attention to JVIO to be equal to VADJ, otherwise you risk damaging the FPGA and EVAL-AD485x board.

## Supported part

| Part name                               | Resolution | Description                                      |
|-----------------------------------------|:----------:|--------------------------------------------------|
| [AD4857](https://www.analog.com/ad4857) | 16-bit     | Buffered, 8-Channel Simultaneous Sampling, 1 MSPS DAS |

## Building the project

Please enter the folder for the FPGA carrier you want to use and read the README.md.
