# AdaC64 build helpers
KLAUS ?= tests/6502_functional_test.bin

all:
	mkdir -p bin obj
	gprbuild -P emu.gpr -j0

tests: all
	mkdir -p obj/tests obj/tests_dbg
	gprbuild -q -P tests/cpu_test.gpr
	gprbuild -q -P tests/kbd_test.gpr
	gprbuild -q -P tests/debug_test.gpr
	bin/kbd_test
	bin/debug_test
	@if [ -f $(KLAUS) ]; then bin/cpu_test $(KLAUS); else \
	  echo "Skipping CPU test: put Klaus Dormann's 6502_functional_test.bin in tests/"; fi

clean:
	gprclean -q -P emu.gpr
	rm -rf obj bin

.PHONY: all tests clean
