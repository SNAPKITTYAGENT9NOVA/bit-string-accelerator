#!/usr/bin/env python3
#
# LiteX SoC for the LiteFury (Xilinx Artix-7 XC7A100T, PCIe Gen2 x4, M.2 2280 Key-M).
# LiteX supports it as the SQRL Acorn CLE-101, its electrical equivalent
# (litex_boards/platforms/sqrl_acorn.py).
#
# The bit-operation engine (pcie/rtl) is attached to one LitePCIe DMA channel:
#   DMA reader (host -> card) -> 128-bit descriptors -> engine
#   engine -> 128-bit result beats (2 results of 64 bits) -> DMA writer (card -> host)
# Descriptor and result formats: pcie/rtl/bitacc_pcie_core.sv (format version 2,
# readable from the version CSR).
# Word access to the engine's bit store and status counters are CSRs on BAR0.
#
# Build (needs Vivado for the bitstream; the free edition covers the XC7A100T):
#   ./bitacc_litefury.py --build                 # gateware + bitstream
#   ./bitacc_litefury.py --driver                # Linux driver + liblitepcie in build/.../driver
# Generate sources only (no Vivado):
#   ./bitacc_litefury.py --no-compile
#
# The same SoC serves the M.2 slot of the NUC directly or a USB4/Thunderbolt
# enclosure that tunnels PCIe; nothing here depends on the transport.

import os

from migen import *

from litex.gen import *
from litex.soc.interconnect.csr import *
from litex.soc.integration.builder import Builder
from litex.build.generic_platform import Pins

from litex_boards.targets.sqrl_acorn import BaseSoC

FORMAT_VERSION = 3

RTL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rtl")


class BitAcc(LiteXModule):
    """bitacc_pcie_core with CSR access; connect dma_source/dma_sink to a LitePCIe DMA."""

    def __init__(self, platform, dma, lanes=8, words_per_lane=2048, with_match=True):
        word_bits = (lanes * words_per_lane - 1).bit_length()

        # Host word access.
        self.host_word  = CSRStorage(word_bits, description="Bit-store word index for host access.")
        self.host_wdata = CSRStorage(64,        description="Word to write.")
        self.host_ctrl  = CSRStorage(fields=[
            CSRField("write", size=1, offset=0, pulse=True, description="Write host_wdata to host_word."),
            CSRField("read",  size=1, offset=1, pulse=True, description="Read host_word into host_rdata."),
        ])
        self.host_rdata = CSRStatus(64, description="Word read by the last read.")
        self.status     = CSRStatus(fields=[
            CSRField("idle",        size=1, offset=0, description="No operation in flight, no result buffered."),
            CSRField("host_busy",   size=1, offset=1, description="A host word access is pending."),
            CSRField("rdata_valid", size=1, offset=2, description="host_rdata holds the last read."),
        ])
        self.ops_accepted = CSRStatus(32, description="Descriptors accepted since reset.")
        self.results_sent = CSRStatus(32, description="Results sent since reset (multiple of 2).")
        self.config       = CSRStatus(fields=[
            CSRField("lanes",          size=8,  offset=0),
            CSRField("words_per_lane", size=24, offset=8),
        ])
        self.version      = CSRStatus(8, reset=FORMAT_VERSION,
            description="Descriptor/result format version (see bitacc_pcie_core.sv).")
        self.features     = CSRStatus(fields=[
            CSRField("match", size=1, offset=0, reset=int(with_match), description="MATCH unit present."),
        ])
        self.comb += [
            self.config.fields.lanes.eq(lanes),
            self.config.fields.words_per_lane.eq(words_per_lane),
        ]

        self.specials += Instance("bitacc_pcie_core",
            p_LANES          = lanes,
            p_WORDS_PER_LANE = words_per_lane,
            p_WITH_MATCH     = int(with_match),
            i_clk            = ClockSignal("sys"),
            i_reset          = ResetSignal("sys"),
            # host -> card
            i_in_valid       = dma.source.valid,
            o_in_ready       = dma.source.ready,
            i_in_data        = dma.source.data,
            # card -> host
            o_out_valid      = dma.sink.valid,
            i_out_ready      = dma.sink.ready,
            o_out_data       = dma.sink.data,
            # registers
            i_host_word      = self.host_word.storage,
            i_host_wdata     = self.host_wdata.storage,
            i_host_write_stb = self.host_ctrl.fields.write,
            i_host_read_stb  = self.host_ctrl.fields.read,
            o_host_rdata     = self.host_rdata.status,
            o_host_rdata_valid = self.status.fields.rdata_valid,
            o_host_busy      = self.status.fields.host_busy,
            o_idle           = self.status.fields.idle,
            o_ops_accepted   = self.ops_accepted.status,
            o_results_sent   = self.results_sent.status,
        )
        self.comb += dma.sink.last.eq(0)
        for f in ("bitacc_engine.sv", "bitacc_pcie_core.sv"):
            platform.add_source(os.path.join(RTL, f))


class BitAccSoC(BaseSoC):
    def __init__(self, lanes=8, words_per_lane=2048, with_match=True, **kwargs):
        BaseSoC.__init__(self,
            variant            = "cle-101",     # LiteFury-equivalent XC7A100T
            with_pcie          = True,
            pcie_ndmas         = 1,
            **kwargs)
        self.bitacc = BitAcc(self.platform, self.pcie_dma0,
            lanes=lanes, words_per_lane=words_per_lane, with_match=with_match)


def main():
    from litex.build.parser import LiteXArgumentParser
    from litex_boards.platforms import sqrl_acorn
    parser = LiteXArgumentParser(platform=sqrl_acorn.Platform, description="Bit accelerator on LiteFury.")
    parser.add_target_argument("--sys-clk-freq",   default=125e6, type=float, help="System clock frequency.")
    parser.add_target_argument("--lanes",          default=8,     type=int,   help="Engine lanes (power of two).")
    parser.add_target_argument("--words-per-lane", default=2048,  type=int,   help="64-bit words per lane (power of two).")
    parser.add_target_argument("--no-match",       action="store_true",       help="Leave out the MATCH unit.")
    parser.add_target_argument("--driver",         action="store_true",       help="Generate the PCIe driver.")
    # The host drives the engine over PCIe; no soft CPU or UART is needed.
    parser.set_defaults(cpu_type="None", no_uart=True)
    args = parser.parse_args()

    soc = BitAccSoC(
        sys_clk_freq   = args.sys_clk_freq,
        lanes          = args.lanes,
        words_per_lane = args.words_per_lane,
        with_match     = not args.no_match,
        **parser.soc_argdict)
    builder = Builder(soc, **parser.builder_argdict)
    if args.build:
        builder.build(**parser.toolchain_argdict)
    else:
        builder.build(run=False)
    if args.driver:
        from litepcie.software import generate_litepcie_software
        generate_litepcie_software(soc, os.path.join(builder.output_dir, "driver"))


if __name__ == "__main__":
    main()
