// liblitepcie stand-in backed by a Verilator model of bitacc_pcie_core.
//
// Links with the unmodified host program (bitacc_pcie.c) so its CSR accesses,
// descriptor encoding, padding and result checking run against the RTL:
//   - litepcie_readl / litepcie_writel act on the CSR map the LiteX SoC
//     generates (64-bit registers split most-significant word first);
//   - DMA write buffers are streamed into the core's 128-bit input, result beats
//     are collected into DMA_BUFFER_SIZE read buffers.
// The DMA stand-in offers one descriptor per cycle and takes one result beat per
// cycle, with no PCIe latency. At exit it reports the clock cycles the DMA
// phases took (MOCK_REPORT_CYCLES), i.e. the engine's own throughput.
// Only the subset of the library the host program uses is implemented.
#include "Vbitacc_pcie_core.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <sys/time.h>
#include <vector>

extern "C" {
#include "liblitepcie.h"
}

#ifndef MOCK_LANES
#define MOCK_LANES 4
#endif
#ifndef MOCK_WPL
#define MOCK_WPL 64
#endif
#ifndef MOCK_MATCH
#define MOCK_MATCH 1
#endif

static Vbitacc_pcie_core *core;
static uint64_t cycles;
static uint64_t dma_cycles;                         // cycles spent in litepcie_dma_process
static uint64_t dma_in, dma_out;                    // descriptors in, result beats out

static uint32_t host_word;
static uint64_t host_wdata;

static void tick()
{
    core->clk = 0; core->eval();
    core->clk = 1; core->eval();
    cycles++;
}

static void ensure_core()
{
    if (core) return;
    core = new Vbitacc_pcie_core;
    core->reset = 1; core->in_valid = 0; core->out_ready = 0;
    core->host_write_stb = 0; core->host_read_stb = 0;
    for (int i = 0; i < 4; i++) tick();
    core->reset = 0;
    tick();
}

// ------------------------------------------------------------------ CSRs
extern "C" uint32_t litepcie_readl(int, uint32_t addr)
{
    ensure_core();
    tick();
    switch (addr) {
    case CSR_BITACC_HOST_RDATA_ADDR:     return (uint32_t)(core->host_rdata >> 32);
    case CSR_BITACC_HOST_RDATA_ADDR + 4: return (uint32_t)core->host_rdata;
    case CSR_BITACC_STATUS_ADDR:
        return (core->idle << CSR_BITACC_STATUS_IDLE_OFFSET)
             | (core->host_busy << CSR_BITACC_STATUS_HOST_BUSY_OFFSET)
             | (core->host_rdata_valid << CSR_BITACC_STATUS_RDATA_VALID_OFFSET);
    case CSR_BITACC_OPS_ACCEPTED_ADDR:   return core->ops_accepted;
    case CSR_BITACC_RESULTS_SENT_ADDR:   return core->results_sent;
    case CSR_BITACC_CONFIG_ADDR:
        return (MOCK_LANES << CSR_BITACC_CONFIG_LANES_OFFSET)
             | (MOCK_WPL << CSR_BITACC_CONFIG_WORDS_PER_LANE_OFFSET);
    case CSR_BITACC_VERSION_ADDR:        return 3;     // FORMAT_VERSION in bitacc_litefury.py
    case CSR_BITACC_FEATURES_ADDR:       return MOCK_MATCH << CSR_BITACC_FEATURES_MATCH_OFFSET;
    default:
        fprintf(stderr, "mock: read of unmapped CSR 0x%x\n", addr);
        return 0xdeadbeef;
    }
}

extern "C" void litepcie_writel(int, uint32_t addr, uint32_t val)
{
    ensure_core();
    switch (addr) {
    case CSR_BITACC_HOST_WORD_ADDR:      host_word = val; break;
    case CSR_BITACC_HOST_WDATA_ADDR:     host_wdata = (host_wdata & 0xffffffffull) | ((uint64_t)val << 32); break;
    case CSR_BITACC_HOST_WDATA_ADDR + 4: host_wdata = (host_wdata & ~0xffffffffull) | val; break;
    case CSR_BITACC_HOST_CTRL_ADDR:
        // CSRStorage pulse fields: one-cycle strobes with the stored word/data.
        core->host_word = host_word;
        core->host_wdata = host_wdata;
        core->host_write_stb = (val >> CSR_BITACC_HOST_CTRL_WRITE_OFFSET) & 1;
        core->host_read_stb = (val >> CSR_BITACC_HOST_CTRL_READ_OFFSET) & 1;
        tick();
        core->host_write_stb = 0;
        core->host_read_stb = 0;
        break;
    default:
        fprintf(stderr, "mock: write of unmapped CSR 0x%x\n", addr);
    }
    tick();
}

// ------------------------------------------------------------------ DMA
static std::deque<std::vector<char>> to_card;      // filled write buffers
static std::vector<char> pending_write;            // buffer handed to the user
static bool write_handed;
static std::deque<std::vector<char>> to_host;      // completed result buffers
static std::vector<char> current_read;
static std::vector<char> results;                  // partial result buffer
static size_t in_pos;                              // byte position in to_card.front()

extern "C" int litepcie_dma_init(struct litepcie_dma_ctrl *dma, const char *, uint8_t)
{
    ensure_core();
    dma->fds.fd = 3;
    return 0;
}

extern "C" void litepcie_dma_cleanup(struct litepcie_dma_ctrl *)
{
    if (dma_cycles)
        fprintf(stderr, "mock: DMA phases %llu cycles, %llu descriptors in, %llu result beats out, "
                "%.3f cycles/descriptor\n", (unsigned long long)dma_cycles,
                (unsigned long long)dma_in, (unsigned long long)dma_out, (double)dma_cycles / (double)dma_in);
}

extern "C" void litepcie_dma_process(struct litepcie_dma_ctrl *dma)
{
    if (write_handed) {                            // the user filled the last write buffer
        to_card.push_back(pending_write);
        write_handed = false;
    }
    for (int c = 0; c < 20000; c++) {
        // input: one 128-bit descriptor per beat, little-endian
        core->in_valid = 0;
        if (dma->reader_enable && !to_card.empty()) {
            const unsigned char *d = (const unsigned char *)to_card.front().data() + in_pos;
            for (int w = 0; w < 4; w++)
                core->in_data[w] = d[4*w] | d[4*w+1] << 8 | d[4*w+2] << 16 | (uint32_t)d[4*w+3] << 24;
            core->in_valid = 1;
        }
        core->out_ready = dma->writer_enable ? 1 : 0;
        core->clk = 0; core->eval();
        bool in_fire = core->in_valid && core->in_ready;
        bool out_fire = core->out_valid && core->out_ready;
        unsigned char beat[16];
        if (out_fire)
            for (int w = 0; w < 4; w++)
                for (int b = 0; b < 4; b++) beat[4*w + b] = (core->out_data[w] >> (8*b)) & 0xff;
        core->clk = 1; core->eval();
        cycles++;
        dma_cycles++;
        dma_in += in_fire;
        dma_out += out_fire;
        if (in_fire) {
            in_pos += 16;
            if (in_pos == DMA_BUFFER_SIZE) { to_card.pop_front(); in_pos = 0; dma->reader_sw_count++; }
        }
        if (out_fire) {
            results.insert(results.end(), (char *)beat, (char *)beat + 16);
            if (results.size() == DMA_BUFFER_SIZE) { to_host.push_back(results); results.clear(); }
        }
        if (to_card.empty() && !core->out_valid && core->idle) break;
    }
}

extern "C" char *litepcie_dma_next_write_buffer(struct litepcie_dma_ctrl *)
{
    if (write_handed) { to_card.push_back(pending_write); write_handed = false; }
    if (to_card.size() >= 8) return nullptr;       // bounded like the real ring
    pending_write.assign(DMA_BUFFER_SIZE, 0);
    write_handed = true;
    return pending_write.data();
}

extern "C" char *litepcie_dma_next_read_buffer(struct litepcie_dma_ctrl *dma)
{
    if (to_host.empty()) return nullptr;
    current_read = to_host.front();
    to_host.pop_front();
    dma->writer_sw_count++;
    return current_read.data();
}

extern "C" int64_t get_time_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

extern "C" int mock_cycles(void) { return (int)cycles; }
