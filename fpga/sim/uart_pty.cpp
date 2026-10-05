// Runs fpga_top (or, with -DTT_TOP, the Tiny Tapeout top) in Verilator and
// bridges its UART to a pseudo-terminal, so the real host tool (fpga/host) can
// talk to the simulated hardware.
//
//   ./V<top> <file-to-write-pty-path-into>
//
// The UART is bit-banged at CLKS_PER_BIT clocks per bit, exactly as on the
// board. The simulation runs until it receives SIGTERM.
#ifdef TT_TOP
#include "Vtt_um_snapkittyagent9nova_bitacc.h"
using Top = Vtt_um_snapkittyagent9nova_bitacc;
// ui_in[3] = RX, ui_in[7:4],[2:0] = divisor d with 4*d = CPB; uo_out[4] = TX.
static void set_rx(Top& t, int v) {
    const unsigned d = CPB / 4;
    t.ui_in = ((d >> 3) & 0xF) << 4 | (v & 1) << 3 | (d & 7);
}
static int get_tx(Top& t) { return (t.uo_out >> 4) & 1; }
static void set_reset(Top& t, int r) { t.rst_n = !r; t.ena = 1; t.uio_in = 0; }
#else
#include "Vfpga_top.h"
using Top = Vfpga_top;
static void set_rx(Top& t, int v) { t.uart_rx = v; }
static int get_tx(Top& t) { return t.uart_tx; }
static void set_reset(Top& t, int r) { t.reset = r; }
#endif
#include "verilated.h"

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <fcntl.h>
#include <pty.h>
#include <termios.h>
#include <unistd.h>

#ifndef CPB
#define CPB 8
#endif

static volatile std::sig_atomic_t stop = 0;
static void on_signal(int) { stop = 1; }

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <pty-path-file>\n", argv[0]); return 2; }
    int master, slave;
    char name[256];
    struct termios tio;
    cfmakeraw(&tio);
    if (openpty(&master, &slave, name, &tio, nullptr) != 0) { std::perror("openpty"); return 1; }
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    FILE* f = std::fopen(argv[1], "w");
    std::fprintf(f, "%s\n", name);
    std::fclose(f);
    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT, on_signal);

    Verilated::commandArgs(argc, argv);
    Top top;
    top.clk = 0; set_reset(top, 1); set_rx(top, 1);

    std::deque<unsigned char> to_fpga;
    int rx_phase = -1, rx_cnt = 0;              // host -> FPGA serializer
    unsigned rx_frame = 0;
    int tx_state = 0, tx_cnt = 0, tx_bit = 0;   // FPGA -> host deserializer
    unsigned char tx_byte = 0;
    unsigned long long cycle = 0;

    while (!stop) {
        // Poll the pty only every few hundred cycles to keep the simulation fast.
        if ((cycle & 255) == 0) {
            unsigned char buf[256];
            ssize_t n = read(master, buf, sizeof buf);
            for (ssize_t i = 0; i < n; i++) to_fpga.push_back(buf[i]);
        }
        if (cycle == 10) set_reset(top, 0);

        // Serializer: start bit, 8 data bits LSB first, stop bit.
        if (rx_phase < 0 && !to_fpga.empty()) {
            rx_frame = (1u << 9) | (unsigned(to_fpga.front()) << 1);
            to_fpga.pop_front();
            rx_phase = 0; rx_cnt = 0;
        }
        if (rx_phase >= 0) {
            set_rx(top, (rx_frame >> rx_phase) & 1);
            if (++rx_cnt == CPB) { rx_cnt = 0; if (++rx_phase == 10) rx_phase = -1; }
        } else {
            set_rx(top, 1);
        }

        top.clk = 1; top.eval();
        top.clk = 0; top.eval();
        cycle++;

        // Deserializer: sample in the middle of each bit.
        switch (tx_state) {
        case 0:
            if (!get_tx(top)) { tx_state = 1; tx_cnt = CPB / 2; }
            break;
        case 1:
            if (--tx_cnt == 0) {
                if (get_tx(top)) tx_state = 0;            // glitch
                else { tx_state = 2; tx_cnt = CPB; tx_bit = 0; tx_byte = 0; }
            }
            break;
        case 2:
            if (--tx_cnt == 0) {
                tx_byte |= (unsigned char)(get_tx(top) << tx_bit);
                tx_cnt = CPB;
                if (++tx_bit == 8) tx_state = 3;
            }
            break;
        default:
            if (--tx_cnt == 0) {
                if (get_tx(top)) { while (write(master, &tx_byte, 1) < 0 && errno == EAGAIN) {} }
                else std::fprintf(stderr, "uart_pty: framing error\n");
                tx_state = 0;
            }
        }
    }
    top.final();
    close(slave);
    close(master);
    return 0;
}
