// Part of the LinGo project (soc/ Cheshire integration).
//
// LinGo CGRA scratchpad smoke test: verifies the Cheshire <-> LinGo datapath
// (axi_dw_converter 64b<->128b, ID handling, address decode) and the register
// bridge without needing a kernel bitstream:
//
//   * SPM (uncached alias) : LINGO_SPM_BASE     (cached: LINGO_SPM_CACHED_BASE)
//   * registers (AXI-Lite) : LINGO_CSR_BASE
//
// Writes walking patterns over the whole SPM with byte/halfword/word/dword
// accesses, reads them back, and checks the CSR done register is readable.

#include <stdint.h>
#include <stddef.h>
#include "util.h"
#include "dif/clint.h"
#include "dif/uart.h"
#include "params.h"
#include "printf.h"
#include "lingo_regs.h"

static volatile uint8_t  *const spm8  = (void *)LINGO_SPM_BASE;
static volatile uint16_t *const spm16 = (void *)LINGO_SPM_BASE;
static volatile uint32_t *const spm32 = (void *)LINGO_SPM_BASE;
static volatile uint64_t *const spm64 = (void *)LINGO_SPM_BASE;
static volatile uint32_t *const cgra_reg = (void *)LINGO_CSR_BASE;

int main(void) {
    uint32_t rtc_freq = CHS_REGS->rtc_freq.f.ref_freq;
    uint64_t reset_freq = clint_get_core_freq(rtc_freq, 2500);
    uart_init(&__uart_base_addr__, reset_freq, __BOOT_BAUDRATE);

    printf("[CGRA] spm smoke start\r\n");

    int errors = 0;

    // 64-bit walking pattern over the whole SPM (incl. config region)
    for (uint32_t a = 0; a < LINGO_SPM_BYTES; a += 8)
        spm64[a / 8] = 0x5A00000000000000ull | a;
    for (uint32_t a = 0; a < LINGO_SPM_BYTES; a += 8) {
        uint64_t want = 0x5A00000000000000ull | a;
        if (spm64[a / 8] != want) {
            if (errors < 3)
                printf("[CGRA] MISMATCH64 @0x%lx: got 0x%016lx\r\n",
                       (unsigned long)a, (unsigned long)spm64[a / 8]);
            errors++;
        }
    }

    // Sub-word access check (byte strobes through the dw converter)
    spm32[0] = 0xDEADBEEF;
    spm16[2] = 0x1234;              // halfword at offset 4
    spm8[7]  = 0xA5;                // byte at offset 7
    spm16[4] = 0xCAFE;              // halfword at offset 8
    if (spm32[0] != 0xDEADBEEF || spm16[2] != 0x1234 ||
        spm8[7] != 0xA5 || spm16[4] != 0xCAFE) {
        printf("[CGRA] MISMATCH sub-word: 0x%08lx 0x%04lx 0x%02lx 0x%04lx\r\n",
               (unsigned long)spm32[0], (unsigned long)spm16[2],
               (unsigned long)spm8[7], (unsigned long)spm16[4]);
        errors++;
    }

    // CSR port: done register must be readable (it resets to 1 = idle)
    uint32_t done = cgra_reg[LINGO_REG_EXE_DONE_0 / 4];
    if (done != 1) {
        printf("[CGRA] unexpected done reg 0x%08lx\r\n", (unsigned long)done);
        errors++;
    }

    printf(errors ? "[CGRA] spm smoke FAIL: %d errors\r\n" : "[CGRA] spm smoke PASS\r\n",
           errors);

    uart_write_flush(&__uart_base_addr__);
    return errors;
}
