CC ?= cc
PYTHON ?= python3
ifeq ($(OUT),)
$(error OUT must name an existing artifact directory)
endif

.PHONY: check metal
check:
	$(CC) -DOPENGL_PACING_STANDALONE -Wall -Wextra -Werror pacing_sim.c ../opengl_pacing.c -lm -o "$(OUT)/pacing_sim"
	"$(OUT)/pacing_sim"
	$(PYTHON) pacing_drift.py
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) present_stats_test.py

metal: check
	$(CC) -fblocks -DVICE_METAL_TEST -Wall -Wextra -Werror -I.. metal_pixels.m ../metal_renderer_macos.m -framework Cocoa -framework Metal -framework QuartzCore -o "$(OUT)/metal_pixels"
	"$(OUT)/metal_pixels" ../../../../data/Metal/nearest.metal --visible
