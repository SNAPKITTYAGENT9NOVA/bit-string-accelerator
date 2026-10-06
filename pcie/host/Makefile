# Host program for the LitePCIe build. LITEPCIE points at the driver directory
# that pcie/litex/bitacc_litefury.py --driver generates (<build>/driver).
LITEPCIE ?= ../../build/litefury/driver
CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra
LIB      := $(LITEPCIE)/user/liblitepcie
INC      := -I$(LIB) -I$(LITEPCIE)/kernel

# Our code builds with -Werror; the generated library is compiled as shipped.
bitacc_pcie: bitacc_pcie.o litepcie_dma.o litepcie_helpers.o
	$(CC) -o $@ $^ -lm

bitacc_pcie.o: bitacc_pcie.c
	$(CC) $(CFLAGS) -Werror $(INC) -c -o $@ $<

litepcie_%.o: $(LIB)/litepcie_%.c
	$(CC) $(CFLAGS) $(INC) -c -o $@ $<

# CPU baseline for the range operations (no driver needed).
cpu_bench: cpu_bench.c
	$(CC) -O3 -march=native -Wall -Wextra -Werror -o $@ $< -lpthread

clean:
	rm -f bitacc_pcie cpu_bench *.o
.PHONY: clean
