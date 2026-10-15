// Part of the LinGo project (soc/ Cheshire integration).
//
// LinGo CGRA gemm test (8x8 int32, o = 3*(x@y) + 2*o with o = 0), ported
// from the LinGo cocotb flow (simulation/workspace/gemm.py +
// benchmarks/gemm/gemm_cocotb.py). Runs the CGRA attached to Cheshire's
// external AXI/reg ports:
//
//   * CGRA SPM (uncached alias) : LINGO_SPM_BASE (cached: LINGO_SPM_CACHED_BASE)
//   * CGRA registers (AXI-Lite) : LINGO_CSR_BASE
//
// UART prints are kept minimal (115200 baud costs ~87 us/char of sim time)
// and mismatches are counted and returned so the testbench can fail.

#include <stdint.h>
#include <stddef.h>
#include "util.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "printf.h"
#include "lingo_regs.h"
#include "lingo_gemm_cfg.h"

#define GEMM_N              8
#define GEMM_TILE_BYTES     (GEMM_N * GEMM_N * 4)

// SPM buffer layout: taken from the generated config header so the test
// always matches the mapper's config stream (offsets change on re-mapping).
// in_off = {X, Y, O-init}; out_off = {O}. O is read-modify-write.
#define SPM_X               (lingo_gemm_in_off[0])
#define SPM_Y               (lingo_gemm_in_off[1])
#define SPM_OUT             (lingo_gemm_out_off[0])  // initial output values AND result

static volatile uint16_t *const spm16 = (void *)LINGO_SPM_BASE;
static volatile uint32_t *const spm32 = (void *)LINGO_SPM_BASE;
static volatile uint32_t *const cgra_reg = (void *)LINGO_CSR_BASE;

static void cgra_spm_write(uint32_t offs, const void *src, size_t bytes) {
    const uint32_t *s = (const uint32_t *)src;
    volatile uint32_t *d = spm32 + offs / 4;
    for (size_t i = 0; i < bytes / 4; i++) d[i] = s[i];
}

static void cgra_spm_read(uint32_t offs, void *dst, size_t bytes) {
    volatile uint32_t *s = spm32 + offs / 4;
    uint32_t *d = (uint32_t *)dst;
    for (size_t i = 0; i < bytes / 4; i++) d[i] = s[i];
}

// Deterministic pseudo-random full-range uint32
static uint32_t lcg_state = 0x12345678u;
static uint32_t lcg(void) {
    lcg_state = lcg_state * 1103515245u + 12345u;
    return lcg_state;
}

static void wait_cycles(uint64_t cycles) {
    uint64_t start = get_mcycle();
    while (get_mcycle() - start < cycles) asm volatile("nop");
}

int main(void) {
    uint32_t rtc_freq = CHS_REGS->rtc_freq.f.ref_freq;
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__uart_base_addr__, reset_freq, __BOOT_BAUDRATE);

    printf("[CGRA] gemm start\r\n");

    // Per-stage cycle accounting (mcycle), printed as one summary at the end
    uint64_t t_mark = get_mcycle();
    uint64_t c_gold = 0, c_zero = 0, c_cfgwr = 0, c_cfgreg = 0, c_cfgwait = 0,
             c_inwr = 0, c_exec = 0, c_rdchk = 0;

    // Matrices in DRAM: x, y random; o initialized to zero
    static uint32_t x[GEMM_N][GEMM_N], y[GEMM_N][GEMM_N], gold[GEMM_N][GEMM_N],
        result[GEMM_N][GEMM_N];
    static const uint32_t zeros[GEMM_N][GEMM_N] = {0};

    for (int i = 0; i < GEMM_N; i++)
        for (int j = 0; j < GEMM_N; j++) {
            x[i][j] = lcg();
            y[i][j] = lcg();
        }

    // Golden model in uint32 wraparound arithmetic, bit-identical to numpy
    // int32: o = 3 * (x @ y) + 2 * o with o = 0
    for (int i = 0; i < GEMM_N; i++)
        for (int j = 0; j < GEMM_N; j++) {
            uint32_t acc = 0;
            for (int k = 0; k < GEMM_N; k++)
                acc += x[i][k] * y[k][j];
            gold[i][j] = 3 * acc;
        }
    c_gold = get_mcycle() - t_mark; t_mark = get_mcycle();

    // 0. Zero the entire CGRA SPM: the behavioral SRAM starts at X and the
    // kernel dataflow may read scratch locations outside the explicit data
    // buffers, freezing the dataflow on X.
    for (uint32_t a = 0; a < LINGO_SPM_BYTES; a += sizeof(zeros))
        cgra_spm_write(a, zeros, sizeof(zeros));
    c_zero = get_mcycle() - t_mark; t_mark = get_mcycle();

    // 1. Load configuration stream into the config region (16-bit halfwords;
    // the SPM port supports byte strobes)
    for (size_t i = 0; i < LINGO_GEMM_CFG_NUM * 3; i++)
        spm16[LINGO_CFG_BASE / 2 + i] = lingo_gemm_cfg[i];
    c_cfgwr = get_mcycle() - t_mark; t_mark = get_mcycle();

    // 2. Switch configuration: base (offset within the config region), num
    // rows, tile enable, then trigger the load
    cgra_reg[LINGO_REG_CFG_BASE_ADDR_0 / 4] = 0;
    cgra_reg[LINGO_REG_CFG_NUM_0 / 4]       = LINGO_GEMM_CFG_NUM;
    cgra_reg[LINGO_REG_CFG_EN_TILE_0 / 4]   = LINGO_GEMM_TILE_ENS;
    fence();
    c_cfgreg = get_mcycle() - t_mark; t_mark = get_mcycle();
    cgra_reg[LINGO_REG_CFG_EN / 4] = 1;
    // wait_cycles(2000);  // config chain drain (cocotb waits cfg_chain_stages)
    c_cfgwait = get_mcycle() - t_mark; t_mark = get_mcycle();

    // 3. Load input data
    cgra_spm_write(SPM_X, x, GEMM_TILE_BYTES);
    cgra_spm_write(SPM_Y, y, GEMM_TILE_BYTES);
    cgra_spm_write(SPM_OUT, zeros, GEMM_TILE_BYTES);
    fence();
    c_inwr = get_mcycle() - t_mark; t_mark = get_mcycle();

    // 4. Start execution
    cgra_reg[LINGO_REG_EXE_IOB_ENS_0 / 4]  = LINGO_GEMM_IOB_ENS;
    cgra_reg[LINGO_REG_EXE_TILE_ENS_0 / 4] = LINGO_GEMM_TILE_ENS;
    fence();
    cgra_reg[LINGO_REG_EXE_START / 4] = 1;

    // 5. Poll for completion: done bits of all enabled tiles
    uint64_t t_start = get_mcycle();
    while ((cgra_reg[LINGO_REG_EXE_DONE_0 / 4] & LINGO_GEMM_TILE_ENS) != LINGO_GEMM_TILE_ENS) {
        if (get_mcycle() - t_start > 500000000ull) {
            printf("[CGRA] TIMEOUT waiting for done (reg = 0x%08lx)\r\n",
                   (unsigned long)cgra_reg[LINGO_REG_EXE_DONE_0 / 4]);
            return 200;
        }
    }
    c_exec = get_mcycle() - t_mark; t_mark = get_mcycle();

    // 6. Read back result and compare against golden model
    cgra_spm_read(SPM_OUT, result, GEMM_TILE_BYTES);

    int errors = 0;
    for (int i = 0; i < GEMM_N && errors < 20; i++)
        for (int j = 0; j < GEMM_N; j++)
            if (result[i][j] != gold[i][j]) {
                if (errors < 3)
                    printf("[CGRA] MISMATCH [%d][%d]: got 0x%08lx, want 0x%08lx\r\n",
                           i, j, (unsigned long)result[i][j], (unsigned long)gold[i][j]);
                errors++;
            }

    c_rdchk = get_mcycle() - t_mark;
    printf(errors ? "[CGRA] gemm FAIL: %d mismatches\r\n" : "[CGRA] gemm PASS\r\n", errors);

    /* printf("[CGRA] cycles: gold=%lu zero=%lu cfgwr=%lu cfgreg=%lu cfgwait=%lu inwr=%lu exec=%lu rdchk=%lu\r\n",
           (unsigned long)c_gold, (unsigned long)c_zero, (unsigned long)c_cfgwr,
           (unsigned long)c_cfgreg, (unsigned long)c_cfgwait,
           (unsigned long)c_inwr, (unsigned long)c_exec, (unsigned long)c_rdchk);
    */
    uart_write_flush(&__uart_base_addr__);
    return errors;
}
