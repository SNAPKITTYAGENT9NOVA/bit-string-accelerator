/*
 * cpu_bench: the host CPU doing the work of the card's range operations, for
 * comparison with `bitacc_pcie bench` and `make perf`.
 *
 *   make -C pcie/host cpu_bench && ./pcie/host/cpu_bench [threads]
 *
 * Bit store: 16384 64-bit words (128 KiB), the LiteFury default geometry.
 *   count   COUNT over the whole store (popcount)
 *   xor     BULK XOR dry run: count of (lower half ^ upper half)
 *   match   MATCH count of a 16-bit pattern and of a 64-bit pattern at every
 *           bit position (shift-outer, word-inner loop, which compilers
 *           vectorize; the naive per-position loop is checked against it)
 * Each kind runs on 1 thread and on [threads] threads (default: all online
 * CPUs), each thread on its own copy of the store. Build with -O3
 * -march=native for the machine's vector units.
 */
#define _GNU_SOURCE
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define WORDS 16384

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static uint64_t count_ones(const uint64_t *m)
{
    uint64_t c = 0;
    for (int i = 0; i < WORDS; i++) c += (uint64_t)__builtin_popcountll(m[i]);
    return c;
}

static uint64_t xor_count(const uint64_t *m)
{
    uint64_t c = 0;
    for (int i = 0; i < WORDS / 2; i++) c += (uint64_t)__builtin_popcountll(m[i] ^ m[WORDS / 2 + i]);
    return c;
}

/* Positions s in [0, WORDS*64 - 64]: ((bits s..s+63) ^ pat) & mask == 0. */
static uint64_t match_count(const uint64_t *restrict m, uint64_t pat, uint64_t mask)
{
    uint64_t c = 0;
    for (int w = 0; w + 1 < WORDS; w++) c += ((m[w] ^ pat) & mask) == 0;
    for (int p = 1; p < 64; p++) {
        uint64_t cp = 0;
        for (int w = 0; w + 1 < WORDS; w++) {
            uint64_t win = (m[w] >> p) | (m[w + 1] << (64 - p));
            cp += ((win ^ pat) & mask) == 0;
        }
        c += cp;
    }
    return c;
}

static uint64_t match_naive(const uint64_t *m, uint64_t pat, uint64_t mask)
{
    uint64_t c = 0;
    for (int w = 0; w + 1 < WORDS; w++)
        for (int p = 0; p < 64; p++) {
            uint64_t win = p ? (m[w] >> p) | (m[w + 1] << (64 - p)) : m[w];
            c += ((win ^ pat) & mask) == 0;
        }
    return c;
}

enum { K_COUNT, K_XOR, K_MATCH16, K_MATCH64, K_N };
static const char *names[K_N] = {"count (1 Mbit)", "xor (2 x 64 KiB)", "match 16-bit (1 M positions)",
                                 "match 64-bit (1 M positions)"};
static const double units[K_N] = {WORDS * 64.0, WORDS * 32.0, (WORDS - 1) * 64.0, (WORDS - 1) * 64.0};

struct job {
    int kind, reps;
    uint64_t *m;
    uint64_t sink;
};

static void *worker(void *arg)
{
    struct job *j = arg;
    uint64_t s = 0;
    for (int r = 0; r < j->reps; r++) {
        j->m[r & (WORDS - 1)] ^= 1;    /* keep each repetition from being hoisted */
        switch (j->kind) {
        case K_COUNT:   s += count_ones(j->m); break;
        case K_XOR:     s += xor_count(j->m); break;
        case K_MATCH16: s += match_count(j->m, j->m[7] & 0xFFFF, 0xFFFF); break;
        default:        s += match_count(j->m, j->m[7], ~0ull); break;
        }
    }
    j->sink = s;
    return NULL;
}

/* Seconds per operation per thread, with n threads running at once. */
static double run(int kind, int n, int reps)
{
    pthread_t t[256];
    struct job j[256];
    for (int i = 0; i < n; i++) {
        j[i].kind = kind; j[i].reps = reps;
        j[i].m = aligned_alloc(64, WORDS * sizeof(uint64_t));
        uint64_t x = 88172645463325252ull + (uint64_t)i;
        for (int w = 0; w < WORDS; w++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; j[i].m[w] = x; }
    }
    double t0 = now();
    for (int i = 0; i < n; i++) pthread_create(&t[i], NULL, worker, &j[i]);
    for (int i = 0; i < n; i++) pthread_join(t[i], NULL);
    double dt = now() - t0;
    for (int i = 0; i < n; i++) free(j[i].m);
    return dt / reps;
}

int main(int argc, char **argv)
{
    int threads = argc > 1 ? atoi(argv[1]) : (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (threads < 1) threads = 1;
    if (threads > 256) threads = 256;

    /* The vectorized MATCH must agree with the naive one. */
    uint64_t *m = aligned_alloc(64, WORDS * sizeof(uint64_t)), x = 1;
    for (int w = 0; w < WORDS; w++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; m[w] = x; }
    for (int k = 0; k < 4; k++) {
        uint64_t mask = k == 3 ? ~0ull : (1ull << (8 << k)) - 1, pat = m[11 * k + 3] & mask;
        if (match_count(m, pat, mask) != match_naive(m, pat, mask)) {
            fprintf(stderr, "cpu_bench: vectorized and naive MATCH disagree\n");
            return 1;
        }
    }
    free(m);

    printf("128 KiB bit store; time per operation; rates per thread and for all threads\n");
    for (int k = 0; k < K_N; k++) {
        int reps = k >= K_MATCH16 ? 40 : 4000;
        double t1 = run(k, 1, reps), tn = threads > 1 ? run(k, threads, reps) : t1;
        printf("%-30s 1 thread: %9.1f us (%6.1f G/s)   %d threads: %9.1f us each (%6.1f G/s total)\n",
               names[k], t1 * 1e6, units[k] / t1 / 1e9, threads, tn * 1e6, units[k] * threads / tn / 1e9);
    }
    printf("G/s: Gbit/s for count and xor, G positions/s for match.\n");
    return 0;
}
