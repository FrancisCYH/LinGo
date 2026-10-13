# LinGo SoC

Integrates the LinGo CGRA into the [Cheshire](https://github.com/pulp-platform/cheshire) SoC as an external accelerator and runs bare-metal kernels in RTL simulation. Cheshire is a pinned git submodule; no upstream file is modified.

## Preparation

1. Cheshire submodule (from the LinGo repo root)

```
cd LinGo
git submodule update --init soc/cheshire
git -C soc/cheshire submodule update --init sw/deps/printf
```

2. Conda env (skip the first line if you already created the `lingo` env via the top-level README)

```
conda create -n lingo python=3.12
conda activate lingo
pip install peakrdl peakrdl-rawheader hjson mako pyyaml "setuptools<81" flatdict GitPython tabulate

cd LinGo/soc/toolchain
wget https://github.com/pulp-platform/bender/releases/download/v0.27.1/bender-0.27.1-x86_64-linux-gnu.tar.gz
tar -xf bender-0.27.1-x86_64-linux-gnu.tar.gz
cp bender "$CONDA_PREFIX/bin/"
```

3. LinGo hardware and SoC parameters

The CGRA Verilog and the SoC parameter files are generated and not committed; regenerate them after any Chisel or mapper change:

```
cd LinGo/hardware && bash genRTL.sh
cd ../soc
bash util/sync_rtl.sh            # hardware/verilog -> rtl/lingo/, spec/
python3 util/gen_lingo_soc.py    # spec/ -> src/lingo_soc_pkg.sv, sw/include/lingo_regs.h
python3 util/gen_lingo_cfg.py gemm   # gemm test only; needs the mapper output ../benchmarks/gemm/config.bit
```

4. Hardware dependencies (network)

```
cd LinGo/soc
bender checkout                 
bash util/get_sim_models.sh     
```

5. RISC-V bare-metal toolchain (riscv64-unknown-elf-gcc, validated: gcc 16.1.0)

Prebuilt archives are named `<arch>-<libc>-<host>-<compiler>`; **ubuntu-22.04 below is the host OS — pick the package matching yours** from the toolchain [releases](https://github.com/riscv-collab/riscv-gnu-toolchain/releases).

```
cd LinGo/soc/toolchain
wget https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2026.07.15/riscv64-elf-ubuntu-22.04-gcc.tar.xz
tar -xf riscv64-elf-ubuntu-22.04-gcc.tar.xz
```

6. Proprietary tools, installed separately and on `PATH` — versions follow cheshire's docs ([sim](https://pulp-platform.github.io/cheshire/tg/sim/), [xilinx](https://pulp-platform.github.io/cheshire/tg/xilinx/)): QuestaSim `>= 2022.3` (validated: 2024.2); Vivado `>= 2020.2` for the FPGA flow only (validated: 2022.2).

## Build

```
conda activate lingo
cd LinGo/soc

mkdir -p build && cd build
bash gen_vsim_do.sh
vsim -c -do "do lingo.vsim.do; quit"
cd ..

make -C sw lingo_spm.dram.elf lingo_gemm.dram.elf
```

## Run

```
cd LinGo/soc/build
bash run_lingo.sh ../sw/tests/lingo_spm.dram.elf    
bash run_lingo.sh ../sw/tests/lingo_gemm.dram.elf   
```

Each test preloads the ELF into the DRAM model, releases the hart over JTAG, and prints PASS/FAIL over UART.

## License

Cheshire is SHL-0.51 (see `cheshire/LICENSE`); adapted sources retain their original headers. New files follow the license of the LinGo repository.
