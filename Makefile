IVERILOG ?= iverilog
IVERILOG_FLAGS ?=
VVP ?= vvp
VERILATOR ?= verilator
PYTHON ?= python3
BUILD ?= build
RTL := $(shell cat rtl/rtl.f)
TB_CORE := tb/tb_latency_memory.sv tb/tb_core.sv

.PHONY: all test core-test unit generate lint synth clean
all: test
test: unit core-test

$(BUILD):
	mkdir -p $(BUILD)

generate: | $(BUILD)
	$(PYTHON) scripts/gen_tests.py --out $(BUILD)/cases

$(BUILD)/tb_core.vvp: $(RTL) $(TB_CORE) | $(BUILD)
	$(IVERILOG) $(IVERILOG_FLAGS) -g2012 -s tb_core -o $@ $(RTL) $(TB_CORE)

$(BUILD)/tb_core_pc2.vvp: $(RTL) $(TB_CORE) | $(BUILD)
	$(IVERILOG) $(IVERILOG_FLAGS) -g2012 -s tb_core -Ptb_core.RESET_PC=2 -o $@ $(RTL) $(TB_CORE)

$(BUILD)/tb_units.vvp: $(RTL) tb/tb_units.sv | $(BUILD)
	$(IVERILOG) $(IVERILOG_FLAGS) -g2012 -s tb_units -o $@ $(RTL) tb/tb_units.sv

unit: $(BUILD)/tb_units.vvp
	$(VVP) $<

core-test: generate $(BUILD)/tb_core.vvp $(BUILD)/tb_core_pc2.vvp
	$(PYTHON) scripts/run_tests.py --vvp '$(VVP)' --build $(BUILD)

lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module rv32i_core $(RTL)

synth:
	bash scripts/synth.sh

clean:
	rm -rf $(BUILD)
