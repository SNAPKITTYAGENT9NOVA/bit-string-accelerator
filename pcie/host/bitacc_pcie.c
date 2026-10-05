/*
 * bitacc_pcie: host program for the bit accelerator on a LitePCIe card
 * (pcie/litex/bitacc_litefury.py). Built against the driver LiteX generates:
 *
 *   make LITEPCIE=<build>/driver
 *
 *   bitacc_pcie [-c /dev/litepcie0] info
 *   bitacc_pcie [-c /dev/litepcie0] selftest [operations] [seed]
 *
 * selftest loads random data into the whole bit store (CSRs), streams random
 * descriptors through the DMA reader, checks every result returned by the DMA
 * writer against a model of the engine, then reads the bit store back and
 * compares it. It prints the operation throughput of the DMA phase.
 *
 * Descriptor: 16 bytes, little-endian: [63:0] effective bit address,
 * [66:64] opcode. Result: 1 byte per descriptor, 0xA0 | error << 1 | bit.
 * The DMA moves DMA_BUFFER_SIZE bytes per buffer, so a run is padded with
 * no-op descriptors (opcode 7: no write, result "error") to a multiple of
 * DMA_BUFFER_SIZE results.
 */
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

#include "liblitepcie.h"

#define DESC_BYTES 16
#define DESCS_PER_BUFFER (DMA_BUFFER_SIZE / DESC_BYTES)
#define RESULTS_PER_BUFFER DMA_BUFFER_SIZE
#define OP_NOP 7

static const char *device = "/dev/litepcie0";

/* ---------------------------------------------------------------- CSRs */
static uint32_t rd(int fd, uint32_t a) { return litepcie_readl(fd, a); }
static void wr(int fd, uint32_t a, uint32_t v) { litepcie_writel(fd, a, v); }

static uint32_t status(int fd) { return rd(fd, CSR_BITACC_STATUS_ADDR); }
#define ST_IDLE        (1u << CSR_BITACC_STATUS_IDLE_OFFSET)
#define ST_HOST_BUSY   (1u << CSR_BITACC_STATUS_HOST_BUSY_OFFSET)
#define ST_RDATA_VALID (1u << CSR_BITACC_STATUS_RDATA_VALID_OFFSET)

static int wait_status(int fd, uint32_t mask, uint32_t want)
{
    for (int i = 0; i < 1000000; i++)
        if ((status(fd) & mask) == want)
            return 0;
    fprintf(stderr, "bitacc: timeout waiting for status 0x%x (status 0x%x)\n", want, status(fd));
    return -1;
}

/* 64-bit CSRs: most significant word at the lower address (CSR_ORDERING_BIG). */
static int word_write(int fd, uint32_t index, uint64_t v)
{
    wr(fd, CSR_BITACC_HOST_WORD_ADDR, index);
    wr(fd, CSR_BITACC_HOST_WDATA_ADDR, (uint32_t)(v >> 32));
    wr(fd, CSR_BITACC_HOST_WDATA_ADDR + 4, (uint32_t)v);
    wr(fd, CSR_BITACC_HOST_CTRL_ADDR, 1u << CSR_BITACC_HOST_CTRL_WRITE_OFFSET);
    return wait_status(fd, ST_HOST_BUSY, 0);
}

static int word_read(int fd, uint32_t index, uint64_t *v)
{
    wr(fd, CSR_BITACC_HOST_WORD_ADDR, index);
    wr(fd, CSR_BITACC_HOST_CTRL_ADDR, 1u << CSR_BITACC_HOST_CTRL_READ_OFFSET);
    if (wait_status(fd, ST_HOST_BUSY | ST_RDATA_VALID, ST_RDATA_VALID))
        return -1;
    *v = ((uint64_t)rd(fd, CSR_BITACC_HOST_RDATA_ADDR) << 32) | rd(fd, CSR_BITACC_HOST_RDATA_ADDR + 4);
    return 0;
}

static void geometry(int fd, uint32_t *lanes, uint32_t *wpl)
{
    uint32_t c = rd(fd, CSR_BITACC_CONFIG_ADDR);
    *lanes = (c >> CSR_BITACC_CONFIG_LANES_OFFSET) & 0xff;
    *wpl = c >> CSR_BITACC_CONFIG_WORDS_PER_LANE_OFFSET;
}

/* ---------------------------------------------------------------- model */
/* Same rules as rtl/bit_accelerator.sv and pcie/rtl/bitacc_engine.sv. */
static uint8_t model(uint64_t *mem, uint64_t words, uint8_t op, uint64_t bit)
{
    uint64_t w = bit >> 6;
    unsigned b = bit & 63;
    if (w >= words || op > 4)
        return 0xA2;
    uint64_t m = 1ull << b, old = (mem[w] >> b) & 1, nb;
    switch (op) {
    case 2: mem[w] |= m;  nb = 1;    break;
    case 3: mem[w] &= ~m; nb = 0;    break;
    case 4: mem[w] ^= m;  nb = !old; break;
    default:              nb = old;  break;
    }
    return 0xA0 | (uint8_t)nb;
}

static uint64_t rng_state;
static uint64_t rng(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

/* ---------------------------------------------------------------- selftest */
static int selftest(uint64_t ops, uint64_t seed)
{
    int rc = 1;
    uint32_t lanes, wpl;
    struct litepcie_dma_ctrl dma = {.use_reader = 1, .use_writer = 1};

    if (litepcie_dma_init(&dma, device, 0))
        return 1;
    int fd = dma.fds.fd;
    geometry(fd, &lanes, &wpl);
    uint64_t words = (uint64_t)lanes * wpl;
    printf("bit store: %u lanes x %u words = %" PRIu64 " KiB\n", lanes, wpl, words * 8 / 1024);
    if (!(status(fd) & ST_IDLE)) {
        fprintf(stderr, "bitacc: engine not idle; reload the FPGA\n");
        goto out;
    }

    uint64_t total = (ops + RESULTS_PER_BUFFER - 1) / RESULTS_PER_BUFFER * RESULTS_PER_BUFFER;
    uint64_t *mem = calloc(words, sizeof *mem);
    uint8_t  *expect = malloc(total);
    uint8_t  *desc = malloc(total * DESC_BYTES);
    if (!mem || !expect || !desc) { perror("malloc"); goto out; }

    /* Load the bit store and a shadow copy. */
    rng_state = seed ? seed : 1;
    for (uint64_t w = 0; w < words; w++) {
        mem[w] = rng();
        if (word_write(fd, (uint32_t)w, mem[w])) goto out;
    }

    /* Build descriptors and expected results (model runs in descriptor order). */
    uint32_t ops_before = rd(fd, CSR_BITACC_OPS_ACCEPTED_ADDR);
    for (uint64_t n = 0; n < total; n++) {
        uint8_t op;
        uint64_t bit;
        if (n >= ops) {
            op = OP_NOP; bit = 0;
        } else {
            uint64_t r = rng();
            op = (r % 12 == 0) ? 5 + (r >> 8) % 3 : (r >> 8) % 5;
            if (r % 10 == 0)       bit = rng();                          /* anywhere, mostly out of range */
            else if (r % 10 == 1)  bit = words * 64 + rng() % 4096;      /* just past the end */
            else                   bit = rng() % (words * 64);
        }
        expect[n] = model(mem, words, op, bit);
        uint8_t *d = desc + n * DESC_BYTES;
        memset(d, 0, DESC_BYTES);
        for (int i = 0; i < 8; i++) d[i] = (uint8_t)(bit >> (8 * i));
        d[8] = op;
    }

    /* Stream. */
    uint64_t sent = 0, got = 0, mismatches = 0;
    int64_t t0 = get_time_ms();
    dma.reader_enable = 1;
    dma.writer_enable = 1;
    while (got < total) {
        litepcie_dma_process(&dma);
        char *buf;
        while (sent < total && (buf = litepcie_dma_next_write_buffer(&dma))) {
            memcpy(buf, desc + sent * DESC_BYTES, DMA_BUFFER_SIZE);
            sent += DESCS_PER_BUFFER;
        }
        while ((buf = litepcie_dma_next_read_buffer(&dma))) {
            for (uint64_t i = 0; i < RESULTS_PER_BUFFER && got < total; i++, got++) {
                uint8_t r = (uint8_t)buf[i];
                uint8_t e = expect[got];
                int bad = (r & 0xFC) != 0xA0 || (r & 2) != (e & 2) || (!(e & 2) && (r & 1) != (e & 1));
                if (bad && mismatches++ < 10)
                    fprintf(stderr, "result %" PRIu64 ": got 0x%02x, expected 0x%02x\n", got, r, e);
            }
        }
        if (get_time_ms() - t0 > 60000) {
            fprintf(stderr, "bitacc: timeout after %" PRIu64 " of %" PRIu64 " results\n", got, total);
            mismatches++;
            break;
        }
    }
    int64_t ms = get_time_ms() - t0;
    dma.reader_enable = 0;
    dma.writer_enable = 0;
    litepcie_dma_process(&dma);

    uint32_t accepted = rd(fd, CSR_BITACC_OPS_ACCEPTED_ADDR) - ops_before;
    if (accepted != (uint32_t)total) {
        fprintf(stderr, "ops_accepted advanced by %u, expected %" PRIu64 "\n", accepted, total);
        mismatches++;
    }

    /* Compare the bit store. */
    if (wait_status(fd, ST_IDLE, ST_IDLE)) mismatches++;
    for (uint64_t w = 0; w < words; w++) {
        uint64_t v;
        if (word_read(fd, (uint32_t)w, &v)) { mismatches++; break; }
        if (v != mem[w] && mismatches++ < 20)
            fprintf(stderr, "word %" PRIu64 ": 0x%016" PRIx64 ", expected 0x%016" PRIx64 "\n", w, v, mem[w]);
    }

    printf("selftest: %" PRIu64 " operations (+%" PRIu64 " padding), %" PRIu64 " words checked, "
           "%" PRIu64 " mismatches\n", ops, total - ops, words, mismatches);
    if (ms > 0)
        printf("DMA phase: %.2f M operations/s (%" PRId64 " ms)\n", (double)total / ms / 1000.0, ms);
    rc = mismatches ? 1 : 0;
    free(mem); free(expect); free(desc);
out:
    litepcie_dma_cleanup(&dma);
    return rc;
}

static int info(void)
{
    int fd = open(device, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(device); return 1; }
    uint32_t lanes, wpl;
    geometry(fd, &lanes, &wpl);
    uint32_t s = status(fd);
    printf("lanes %u, words per lane %u, idle %u, ops accepted %u, results sent %u\n",
           lanes, wpl, !!(s & ST_IDLE), rd(fd, CSR_BITACC_OPS_ACCEPTED_ADDR), rd(fd, CSR_BITACC_RESULTS_SENT_ADDR));
    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    int i = 1;
    if (i + 1 < argc && !strcmp(argv[i], "-c")) { device = argv[i + 1]; i += 2; }
    if (i < argc && !strcmp(argv[i], "info"))
        return info();
    if (i < argc && !strcmp(argv[i], "selftest")) {
        uint64_t ops = (i + 1 < argc) ? strtoull(argv[i + 1], NULL, 0) : 1000000;
        uint64_t seed = (i + 2 < argc) ? strtoull(argv[i + 2], NULL, 0) : 1;
        return selftest(ops, seed);
    }
    fprintf(stderr, "usage: %s [-c device] info | selftest [operations] [seed]\n", argv[0]);
    return 2;
}
