/*
 * bitacc_pcie: host program for the bit accelerator on a LitePCIe card
 * (pcie/litex/bitacc_litefury.py). Built against the driver LiteX generates:
 *
 *   make LITEPCIE=<build>/driver
 *
 *   bitacc_pcie [-c /dev/litepcie0] info
 *   bitacc_pcie [-c /dev/litepcie0] selftest [operations] [seed] [range-percent]
 *   bitacc_pcie [-c /dev/litepcie0] bench get|count|find|xor|match [descriptors]
 *
 * selftest loads random data into the whole bit store (CSRs), streams random
 * descriptors (single-bit and range operations) through the DMA reader, checks
 * every result returned by the DMA writer against a model of the engine, then
 * reads the bit store back and compares it. It prints the descriptor
 * throughput of the DMA phase.
 *
 * bench streams one kind of descriptor and prints descriptors/s and the bits
 * of the bit store they cover per second:
 *   get    random single-bit GETs
 *   count  COUNT over the whole bit store
 *   find   FIND1 over the whole bit store, which bench clears first (not found)
 *   xor    BULK XOR, dry run, of the lower half of the store with the upper half
 *   match  MATCH (count) of a 16-bit pattern over the whole bit store
 *
 * Descriptor (16 bytes, little-endian), format version 3:
 *   [63:0] a  [67:64] op  [68] dry  [71:69] fn  [103:72] len  [127:104] src
 * Result (8 bytes, little-endian): [7:0] 0xA0 | error << 1 | bit, [63:8] value.
 * Semantics: pcie/rtl/bitacc_engine.sv. The DMA moves DMA_BUFFER_SIZE bytes
 * per buffer, so a run is padded with no-op descriptors (opcode 7: no write,
 * result "error") to whole buffers in both directions.
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

#define FORMAT_VERSION 3
#define DESC_BYTES 16
#define RESULT_BYTES 8
#define DESCS_PER_BUFFER (DMA_BUFFER_SIZE / DESC_BYTES)
#define RESULTS_PER_BUFFER (DMA_BUFFER_SIZE / RESULT_BYTES)
/* A run fills whole buffers in both directions. */
#define RUN_QUANTUM (DESCS_PER_BUFFER > RESULTS_PER_BUFFER ? DESCS_PER_BUFFER : RESULTS_PER_BUFFER)

enum { OP_GET, OP_TEST, OP_SET, OP_CLEAR, OP_TOGGLE, OP_NOP = 7,
       OP_COUNT = 8, OP_FIND1, OP_FIND0, OP_SETR, OP_CLEARR, OP_FLIPR, OP_BULK, OP_MATCH };
enum { FN_COPY, FN_AND, FN_OR, FN_XOR, FN_ANDN };
#define RESULT_ERROR 0xA2ull

struct desc {
    uint64_t a;          /* bit address, or dst word (BULK) */
    uint8_t  op, fn, dry;
    uint32_t len;        /* bits, or words (BULK) */
    uint32_t src;        /* src word (BULK), pattern word (MATCH; mask in src + 1), 24 bits */
};

static const char *device = "/dev/litepcie0";
static int has_match;    /* gateware has the MATCH unit (features CSR) */

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

static int check_version(int fd)
{
    uint32_t v = rd(fd, CSR_BITACC_VERSION_ADDR);
    if (v != FORMAT_VERSION) {
        fprintf(stderr, "bitacc: gateware descriptor format %u, this program speaks %u\n", v, FORMAT_VERSION);
        return -1;
    }
    has_match = (rd(fd, CSR_BITACC_FEATURES_ADDR) >> CSR_BITACC_FEATURES_MATCH_OFFSET) & 1;
    return 0;
}

/* ---------------------------------------------------------------- descriptors */
static void encode(uint8_t *d, const struct desc *x)
{
    for (int i = 0; i < 8; i++) d[i] = (uint8_t)(x->a >> (8 * i));
    d[8] = (uint8_t)((x->op & 15) | (x->dry & 1) << 4 | (x->fn & 7) << 5);
    for (int i = 0; i < 4; i++) d[9 + i] = (uint8_t)(x->len >> (8 * i));
    for (int i = 0; i < 3; i++) d[13 + i] = (uint8_t)(x->src >> (8 * i));
}

static uint64_t decode_result(const char *p)
{
    uint64_t r = 0;
    for (int i = 0; i < 8; i++) r |= (uint64_t)(uint8_t)p[i] << (8 * i);
    return r;
}

/* ---------------------------------------------------------------- model */
/*
 * Word-level model of pcie/rtl/bitacc_engine.sv: returns the expected 64-bit
 * result and applies the operation to mem. It is written independently of
 * the RTL testbenches, which expand range operations bit by bit on the
 * reference core.
 */
static uint64_t result(int bit, uint64_t value) { return 0xA0ull | (uint64_t)(bit != 0) | value << 8; }

static uint64_t model(uint64_t *mem, uint64_t words, const struct desc *x)
{
    uint64_t bits = words * 64;
    if (x->op <= OP_TOGGLE) {
        uint64_t w = x->a >> 6;
        unsigned b = x->a & 63;
        if (w >= words)
            return RESULT_ERROR;
        uint64_t m = 1ull << b, old = (mem[w] >> b) & 1, nb;
        switch (x->op) {
        case OP_SET:    mem[w] |= m;  nb = 1;    break;
        case OP_CLEAR:  mem[w] &= ~m; nb = 0;    break;
        case OP_TOGGLE: mem[w] ^= m;  nb = !old; break;
        default:                      nb = old;  break;
        }
        return result((int)nb, 0);
    }
    if (x->op >= OP_COUNT && x->op <= OP_FLIPR) {
        if (x->a > bits || x->len > bits - x->a)
            return RESULT_ERROR;
        int find = x->op == OP_FIND1 || x->op == OP_FIND0, found = 0;
        uint64_t cnt = 0, idx = 0, end = x->a + x->len;
        for (uint64_t b = x->a; b < end && !found; ) {
            uint64_t w = b >> 6;
            unsigned lo = b & 63;
            uint64_t n = 64 - lo < end - b ? 64 - lo : end - b;
            uint64_t m = (n == 64 ? ~0ull : (1ull << n) - 1) << lo;
            uint64_t v = mem[w], hit;
            switch (x->op) {
            case OP_COUNT:  cnt += (uint64_t)__builtin_popcountll(v & m); break;
            case OP_FIND1:
            case OP_FIND0:
                hit = (x->op == OP_FIND1 ? v : ~v) & m;
                if (hit) { found = 1; idx = w * 64 + (uint64_t)__builtin_ctzll(hit); }
                break;
            case OP_SETR:   cnt += (uint64_t)__builtin_popcountll(v & m); mem[w] = v | m;  break;
            case OP_CLEARR: cnt += (uint64_t)__builtin_popcountll(v & m); mem[w] = v & ~m; break;
            default:        cnt += (uint64_t)__builtin_popcountll(v & m); mem[w] = v ^ m;  break;
            }
            b += n;
        }
        return find ? result(found, found ? idx : 0) : result(cnt != 0, cnt);
    }
    if (x->op == OP_MATCH) {
        uint64_t a = x->a, n = x->len, p = x->src;
        if (!has_match || x->fn > 1 || a > bits || n > bits - a || p + 2 > words)
            return RESULT_ERROR;
        uint64_t pat = mem[p], msk = mem[p + 1];
        /* position s is valid if every mask bit lies inside the haystack */
        uint64_t top = msk ? 63 - (uint64_t)__builtin_clzll(msk) : 0, cnt = 0, first = 0;
        int found = 0;
        for (uint64_t s = a; s < a + n && s + top < a + n; s++) {
            uint64_t w = s >> 6, o = s & 63;
            uint64_t lo = mem[w], hi = w + 1 < words ? mem[w + 1] : 0;
            uint64_t win = o ? (lo >> o) | (hi << (64 - o)) : lo;
            if (((win ^ pat) & msk) == 0) {
                cnt++;
                if (!found) { found = 1; first = s; }
            }
        }
        return x->fn ? result(found, first) : result(cnt != 0, cnt);
    }
    if (x->op == OP_BULK) {
        uint64_t d = x->a, s = x->src, n = x->len;
        if (x->fn > FN_ANDN || d > words || n > words - d || s > words || n > words - s)
            return RESULT_ERROR;
        if (n && d != s && d < s + n && s < d + n)
            return RESULT_ERROR;                       /* overlapping, not identical */
        uint64_t cnt = 0;
        for (uint64_t k = 0; k < n; k++) {
            uint64_t a = mem[d + k], b = mem[s + k], r;
            switch (x->fn) {
            case FN_COPY: r = b;      break;
            case FN_AND:  r = a & b;  break;
            case FN_OR:   r = a | b;  break;
            case FN_XOR:  r = a ^ b;  break;
            default:      r = a & ~b; break;
            }
            cnt += (uint64_t)__builtin_popcountll(r);
            if (!x->dry) mem[d + k] = r;
        }
        return result(cnt != 0, cnt);
    }
    return RESULT_ERROR;                               /* 5-7 */
}

static uint64_t rng_state;
static uint64_t rng(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

static uint64_t umin(uint64_t a, uint64_t b) { return a < b ? a : b; }

/* A MATCH preceded by operations that build its mask (and sometimes its
 * pattern) in the bit store; returns the number of descriptors (<= 4). */
static int match_seq(struct desc *x, uint64_t words)
{
    uint64_t bits = words * 64, pw = rng() % (words - 1), mw = (pw + 1) * 64;
    uint64_t lc = rng() % 100, l = lc < 45 ? rng() % 300 : lc < 95 ? rng() % (64 * umin(words, 64) + 1) : 0;
    uint64_t a = rng() % (bits - l + 1), m = rng() % 100;
    int n = 0;
    memset(x, 0, 4 * sizeof *x);
    if (m < 40) {                                      /* contiguous k bits at offset o */
        uint64_t k = 1 + rng() % 12, o = rng() % (64 - k + 1);
        x[n].op = OP_CLEARR; x[n].a = mw; x[n++].len = 64;
        x[n].op = OP_SETR; x[n].a = mw + o; x[n++].len = (uint32_t)k;
    } else if (m < 50) {                               /* zero mask */
        x[n].op = OP_CLEARR; x[n].a = mw; x[n++].len = 64;
    } else if (m < 65 && l >= 64) {                    /* pattern = a haystack word, full mask */
        uint64_t h = (a + 63) / 64 + rng() % (l / 64);
        if (h >= words) h = words - 1;
        x[n].op = OP_BULK; x[n].fn = FN_COPY; x[n].a = pw; x[n].src = (uint32_t)h; x[n++].len = 1;
        x[n].op = OP_SETR; x[n].a = mw; x[n++].len = 64;
    } else if (m < 80) {                               /* two far-apart bits */
        x[n].op = OP_CLEARR; x[n].a = mw; x[n++].len = 64;
        x[n].op = OP_SETR; x[n].a = mw + rng() % 8; x[n++].len = 1;
        x[n].op = OP_SETR; x[n].a = mw + 56 + rng() % 8; x[n++].len = 1;
    }                                                  /* else the mask word as it is */
    x[n].op = OP_MATCH; x[n].a = a; x[n].len = (uint32_t)l;
    x[n].src = rng() % 25 == 0 ? (uint32_t)(words - 1) : (uint32_t)pw;   /* past the end: error */
    x[n].fn = rng() % 12 == 0 ? (uint8_t)(2 + rng() % 6) : (uint8_t)(rng() % 2);
    return n + 1;
}

/* One or more descriptors (a MATCH sequence); returns how many (<= 4). */
static int random_desc(struct desc *x, uint64_t words, unsigned range_pct)
{
    uint64_t bits = words * 64, r = rng();
    memset(x, 0, sizeof *x);
    if (r % 100 >= range_pct) {                        /* single-bit */
        x->op = (r >> 8) % 12 == 0 ? (uint8_t)(5 + (r >> 16) % 3) : (uint8_t)((r >> 16) % 5);
        if (r % 10 == 0)       x->a = rng();                          /* anywhere, mostly out of range */
        else if (r % 10 == 1)  x->a = bits + rng() % 4096;            /* just past the end */
        else                   x->a = rng() % bits;
        return 1;
    }
    uint64_t c = rng() % 100, l;
    if (c < 20)
        return match_seq(x, words);
    if (c < 23) {                                      /* undefined */
        x->op = (uint8_t)(5 + rng() % 3); x->a = rng() % bits; x->len = (uint32_t)(rng() % 64);
    } else if (c < 60) {                               /* bit range */
        x->op = (uint8_t)(OP_COUNT + rng() % 6);
        uint64_t lc = rng() % 100;
        l = lc < 50 ? rng() % 130 : lc < 92 ? rng() % (64 * umin(words, 64) + 1) : lc < 96 ? 0 : bits;
        x->len = (uint32_t)l;
        x->a = rng() % 100 < 94 ? rng() % (bits - l + 1) : bits - l + 1 + rng() % 64;
    } else {                                           /* BULK */
        x->op = OP_BULK;
        x->fn = rng() % 20 == 0 ? (uint8_t)(5 + rng() % 3) : (uint8_t)(rng() % 5);
        x->dry = rng() % 5 == 0;
        l = rng() % (umin(words / 2, 256) + 1);
        x->len = (uint32_t)l;
        x->src = (uint32_t)(rng() % (words - l + 1));
        uint64_t pc = rng() % 100, d = rng() % (words - l + 1);
        if (pc < 70) {
            for (int t = 0; t < 50 && l && d < x->src + l && x->src < d + l; t++)
                d = rng() % (words - l + 1);
        } else if (pc < 85) {
            d = x->src;
        } else if (pc < 95) {
            d = x->src + 1 + rng() % (l > 1 ? l - 1 : 1);  /* overlapping: error */
        } else {
            d = words - l + 1 + rng() % 8;              /* past the end: error */
        }
        x->a = d;
    }
    return 1;
}

/* ---------------------------------------------------------------- streaming */
/*
 * Streams total descriptors (a multiple of RUN_QUANTUM) and stores the 64-bit
 * results. Returns the elapsed milliseconds, or -1 on timeout.
 */
static int64_t stream(struct litepcie_dma_ctrl *dma, const uint8_t *desc, uint64_t total, uint64_t *res)
{
    uint64_t sent = 0, got = 0;
    int64_t t0 = get_time_ms(), ms;
    dma->reader_enable = 1;
    dma->writer_enable = 1;
    while (got < total) {
        litepcie_dma_process(dma);
        char *buf;
        while (sent < total && (buf = litepcie_dma_next_write_buffer(dma))) {
            memcpy(buf, desc + sent * DESC_BYTES, DMA_BUFFER_SIZE);
            sent += DESCS_PER_BUFFER;
        }
        while ((buf = litepcie_dma_next_read_buffer(dma)))
            for (uint64_t i = 0; i < RESULTS_PER_BUFFER && got < total; i++, got++)
                res[got] = decode_result(buf + i * RESULT_BYTES);
        if (get_time_ms() - t0 > 120000) {
            fprintf(stderr, "bitacc: timeout after %" PRIu64 " of %" PRIu64 " results\n", got, total);
            break;
        }
    }
    ms = get_time_ms() - t0;
    dma->reader_enable = 0;
    dma->writer_enable = 0;
    litepcie_dma_process(dma);
    return got == total ? ms : -1;
}

static int open_engine(struct litepcie_dma_ctrl *dma, uint64_t *words)
{
    uint32_t lanes, wpl;
    if (litepcie_dma_init(dma, device, 0))
        return -1;
    int fd = dma->fds.fd;
    if (check_version(fd))
        return -1;
    geometry(fd, &lanes, &wpl);
    *words = (uint64_t)lanes * wpl;
    printf("bit store: %u lanes x %u words = %" PRIu64 " KiB\n", lanes, wpl, *words * 8 / 1024);
    if (!(status(fd) & ST_IDLE)) {
        fprintf(stderr, "bitacc: engine not idle; reload the FPGA\n");
        return -1;
    }
    return fd;
}

/* ---------------------------------------------------------------- selftest */
static int selftest(uint64_t ops, uint64_t seed, unsigned range_pct)
{
    int rc = 1;
    uint64_t words;
    struct litepcie_dma_ctrl dma = {.use_reader = 1, .use_writer = 1};
    uint64_t *mem = NULL, *expect = NULL, *res = NULL;
    uint8_t *desc = NULL;

    int fd = open_engine(&dma, &words);
    if (fd < 0)
        goto out;

    uint64_t total = (ops + RUN_QUANTUM - 1) / RUN_QUANTUM * RUN_QUANTUM;
    mem = calloc(words, sizeof *mem);
    expect = malloc(total * sizeof *expect);
    res = malloc(total * sizeof *res);
    desc = malloc(total * DESC_BYTES);
    if (!mem || !expect || !res || !desc) { perror("malloc"); goto out; }

    /* Load the bit store and a shadow copy. */
    rng_state = seed ? seed : 1;
    for (uint64_t w = 0; w < words; w++) {
        mem[w] = rng();
        if (word_write(fd, (uint32_t)w, mem[w])) goto out;
    }

    /* Build descriptors and expected results (model runs in descriptor order). */
    uint64_t n_range = 0, n_range_ok = 0, n_match = 0, n_match_hit = 0;
    uint32_t ops_before = rd(fd, CSR_BITACC_OPS_ACCEPTED_ADDR);
    struct desc xs[4];
    int nx = 0, ix = 0;
    for (uint64_t n = 0; n < total; n++) {
        struct desc x;
        if (ix == nx && n < ops) {
            nx = random_desc(xs, words, range_pct);
            ix = 0;
        }
        if (ix < nx) {
            x = xs[ix++];                              /* may run past ops: padding then starts later */
        } else {
            memset(&x, 0, sizeof x);
            x.op = OP_NOP;
        }
        expect[n] = model(mem, words, &x);
        if (x.op >= OP_COUNT) {
            n_range++;
            n_range_ok += expect[n] != RESULT_ERROR;
            n_match += x.op == OP_MATCH && expect[n] != RESULT_ERROR;
            n_match_hit += x.op == OP_MATCH && (expect[n] & 0xFF) == 0xA1;
        }
        encode(desc + n * DESC_BYTES, &x);
    }

    uint64_t mismatches = 0;
    int64_t ms = stream(&dma, desc, total, res);
    if (ms < 0) mismatches++;
    for (uint64_t n = 0; n < total && ms >= 0; n++)
        if (res[n] != expect[n] && mismatches++ < 10)
            fprintf(stderr, "result %" PRIu64 ": got 0x%016" PRIx64 ", expected 0x%016" PRIx64 "\n",
                    n, res[n], expect[n]);

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

    printf("selftest: %" PRIu64 " descriptors (%" PRIu64 " range, %" PRIu64 " of them valid, %" PRIu64
           " valid MATCH with %" PRIu64 " hits), %" PRIu64 " words checked, %" PRIu64 " mismatches\n",
           total, n_range, n_range_ok, n_match, n_match_hit, words, mismatches);
    if (ms > 0)
        printf("DMA phase: %.2f M descriptors/s (%" PRId64 " ms)\n", (double)total / ms / 1000.0, ms);
    rc = mismatches ? 1 : 0;
out:
    free(mem); free(expect); free(res); free(desc);
    litepcie_dma_cleanup(&dma);
    return rc;
}

/* ---------------------------------------------------------------- bench */
static int bench(const char *kind, uint64_t n)
{
    int rc = 1;
    uint64_t words;
    struct litepcie_dma_ctrl dma = {.use_reader = 1, .use_writer = 1};
    uint64_t *res = NULL;
    uint8_t *desc = NULL;

    int fd = open_engine(&dma, &words);
    if (fd < 0)
        goto out;
    uint64_t total = (n + RUN_QUANTUM - 1) / RUN_QUANTUM * RUN_QUANTUM;
    res = malloc(total * sizeof *res);
    desc = malloc(total * DESC_BYTES);
    if (!res || !desc) { perror("malloc"); goto out; }

    struct desc x = {0};
    uint64_t bits_per_desc;
    if (!strcmp(kind, "get")) {
        x.op = OP_GET; bits_per_desc = 1;
    } else if (!strcmp(kind, "count")) {
        x.op = OP_COUNT; x.len = (uint32_t)(words * 64); bits_per_desc = words * 64;
    } else if (!strcmp(kind, "find")) {
        x.op = OP_FIND1; x.len = (uint32_t)(words * 64); bits_per_desc = words * 64;
        for (uint64_t w = 0; w < words; w++)
            if (word_write(fd, (uint32_t)w, 0)) goto out;
    } else if (!strcmp(kind, "match")) {
        if (!has_match) { fprintf(stderr, "bench: the gateware has no MATCH unit\n"); goto out; }
        x.op = OP_MATCH; x.fn = 0; x.src = 0; x.len = (uint32_t)(words * 64); bits_per_desc = words * 64;
        if (word_write(fd, 0, 0xBEEF) || word_write(fd, 1, 0xFFFF)) goto out;   /* 16-bit pattern */
    } else if (!strcmp(kind, "xor")) {
        x.op = OP_BULK; x.fn = FN_XOR; x.dry = 1; x.a = words / 2; x.src = 0; x.len = (uint32_t)(words / 2);
        bits_per_desc = words / 2 * 64;
    } else {
        fprintf(stderr, "bench: unknown kind '%s' (get, count, find, xor, match)\n", kind);
        goto out;
    }
    rng_state = 1;
    for (uint64_t i = 0; i < total; i++) {
        if (x.op == OP_GET) x.a = rng() % (words * 64);
        encode(desc + i * DESC_BYTES, &x);
    }

    int64_t ms = stream(&dma, desc, total, res);
    uint64_t errors = 0;
    for (uint64_t i = 0; i < total && ms >= 0; i++)
        errors += (res[i] & 0xFE) != 0xA0;
    if (ms < 0 || errors) {
        fprintf(stderr, "bench: %" PRIu64 " error results%s\n", errors, ms < 0 ? ", timeout" : "");
        goto out;
    }
    printf("bench %s: %" PRIu64 " descriptors in %" PRId64 " ms", kind, total, ms);
    if (ms > 0)
        printf(": %.3f M descriptors/s, %.3f Gbit/s of bit store covered",
               (double)total / ms / 1000.0, (double)total * (double)bits_per_desc / ms / 1e6);
    printf("\n");
    rc = 0;
out:
    free(res); free(desc);
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
    printf("format %u, MATCH %s, lanes %u, words per lane %u, idle %u, ops accepted %u, results sent %u\n",
           rd(fd, CSR_BITACC_VERSION_ADDR),
           (rd(fd, CSR_BITACC_FEATURES_ADDR) >> CSR_BITACC_FEATURES_MATCH_OFFSET) & 1 ? "yes" : "no",
           lanes, wpl, !!(s & ST_IDLE),
           rd(fd, CSR_BITACC_OPS_ACCEPTED_ADDR), rd(fd, CSR_BITACC_RESULTS_SENT_ADDR));
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
        unsigned pct = (i + 3 < argc) ? (unsigned)strtoul(argv[i + 3], NULL, 0) : 5;
        return selftest(ops, seed, pct > 100 ? 100 : pct);
    }
    if (i + 1 < argc && !strcmp(argv[i], "bench")) {
        uint64_t n = (i + 2 < argc) ? strtoull(argv[i + 2], NULL, 0) : 100000;
        return bench(argv[i + 1], n);
    }
    fprintf(stderr, "usage: %s [-c device] info | selftest [operations] [seed] [range-percent]"
            " | bench get|count|find|xor|match [descriptors]\n", argv[0]);
    return 2;
}
