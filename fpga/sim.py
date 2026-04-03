from itertools import chain
from pathlib import Path
from vunit import VUnit

# Create VUnit instance by parsing command line arguments
vu = VUnit.from_argv(compile_builtins=False)
vu.add_vhdl_builtins()
vu.add_verification_components()

# Compile Community driven XPM
xpm_lib = vu.add_library('xpm')
xpm_lib.add_source_files('sim/xpm_vhdl/src/xpm/*.vhd')
xpm_lib.add_source_files('sim/xpm_vhdl/src/xpm/xpm_cdc/hdl/*.vhd')
xpm_lib.add_source_files('sim/xpm_vhdl/src/xpm/xpm_memory/hdl/*.vhd')
xpm_lib.add_source_files('sim/xpm_vhdl/src/xpm/xpm_fifo/hdl/*.vhd')

# Unisim
unisim_src = "/tools/Xilinx/Vivado/2024.2/data/vhdl/src/unisims"
unisim_lib = vu.add_library('unisim')
unisim_lib.add_source_file(unisim_src + "/unisim_VCOMP.vhd")
# Primitives without VITAL dependencies - use Xilinx originals
for prim in ["IBUFDS", "BUFG", "OBUFDS"]:
    unisim_lib.add_source_file(unisim_src + f"/primitive/{prim}.vhd")
# IDDR and ODDR depend on vpkg/VITAL - use behavioral stubs
unisim_lib.add_source_files("sim/unisim_stubs/*.vhd")
# Create library 'lib'
lib = vu.add_library("ad936x")

# Add all files ending in .vhd in current working directory to library
rtls = [
    "ad936x_axi_pkg.vhd",
    "ad936x_txrx.vhd",
    "ad936x_axi.vhd",
    "axi_master_wr.vhd",
    "axi_master_rd.vhd",
    "core.vhd",
]

tbs = [
    "tb_ad936x_txrx.vhd",
    "tb_ad936x_axi.vhd",
    "tb_core.vhd",
]

for src in rtls:
    lib.add_source_files("rtl/" + src)

for src in tbs:
    lib.add_source_files("sim/" + src)

tb = lib.test_bench('tb_ad936x_txrx')
assert tb, "tb_ad936x_txrx not found"

tb2 = lib.test_bench('tb_ad936x_axi')
assert tb2, "tb_ad936x_axi not found"

tb3 = lib.test_bench('tb_core')
assert tb3, "tb_core not found"

vu.set_compile_option("ghdl.a_flags", [
    "--std=08",
    "--ieee=synopsys",
    "-frelaxed-rules",
    "--no-vital-checks",
    "-fsynopsys",
])

# Run vunit function
vu.main()
