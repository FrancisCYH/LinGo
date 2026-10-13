# Part of the LinGo project (soc/ Cheshire integration).
#
# Builds the LinGo bare-metal tests in ./tests using Cheshire's own software
# makefiles, WITHOUT modifying the cheshire submodule: Cheshire is resolved
# through the soc/ Bender manifest, and this directory's tests are registered
# through sw.mk's own `chs_sw_tests_add_rule` macro.
#
# Usage (CHS_SW_GCC_BINROOT defaults to ../toolchain/riscv/bin):
#   make -C sw lingo_spm.dram.elf
#   make -C sw lingo_gemm.dram.elf

SOC_ROOT  := $(shell realpath ..)
BENDER    ?= bender -d $(SOC_ROOT)
CHS_ROOT  ?= $(shell $(BENDER) path cheshire)

LINGO_SW_DIR := $(SOC_ROOT)/sw

# Defaults consumed by cheshire.mk / sw.mk (`?=` there keeps ours):
#  - bender database lives in soc/.bender, not inside the cheshire submodule
#  - toolchain defaults to the local archive; override on the command line
#    (CHS_SW_GCC_BINROOT=...) to use another riscv64-unknown-elf-gcc
BENDER_ROOT        := $(SOC_ROOT)/.bender
CHS_SW_GCC_BINROOT ?= $(SOC_ROOT)/toolchain/riscv/bin

# Default goal before any include
all: lingo-tests

include $(CHS_ROOT)/cheshire.mk

# Add the generated lingo_regs.h to the include path (CHS_SW_INCLUDES has `?=`
# semantics in sw.mk; override it here, keeping Cheshire's own paths)
CHS_SW_INCLUDES = -I$(LINGO_SW_DIR)/include -I$(CHS_SW_DIR)/include $(CHS_SW_DEPS_INCS)

# Register ./tests with Cheshire's test machinery (single-link-mode rules)
$(foreach link,$(CHS_SW_LINK_MODES),$(eval $(call chs_sw_tests_add_rule,$(link),$(LINGO_SW_DIR)/tests)))

LINGO_TESTS := $(LINGO_SW_DIR)/tests/lingo_spm.dram.elf \
               $(LINGO_SW_DIR)/tests/lingo_gemm.dram.elf

lingo-tests: $(LINGO_TESTS)

# Bare-name aliases (sw.mk's elf rules are path-based patterns)
lingo_spm.dram.elf:  $(LINGO_SW_DIR)/tests/lingo_spm.dram.elf
lingo_gemm.dram.elf: $(LINGO_SW_DIR)/tests/lingo_gemm.dram.elf

.PHONY: all lingo-tests
