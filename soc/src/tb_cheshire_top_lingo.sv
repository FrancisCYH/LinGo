// Part of the LinGo project (soc/ Cheshire integration).
//
// Testbench for `cheshire_top_lingo`, mirroring `tb_cheshire_soc`.
// Derived from the AuFORA integration (tb_cheshire_top_aufora).
//
// Run (from a build dir with the compiled libraries, see README):
//   vsim -suppress 8386 -c tb_cheshire_top_lingo \
//        +BOOTMODE=0 +PRELMODE=3 +BINARY=<elf> -do "run -a; quit"
//
// Supported preload modes: 0 (JTAG) and 3 (MEMH, recommended). Modes 1
// (Serial Link) and 2 (UART debug) are unavailable: the LinGo top level
// does not expose those interfaces.

module tb_cheshire_top_lingo #(
  parameter bit UseDramSys = 1'b0
);

  fixture_cheshire_top_lingo #(
    .UseDramSys (UseDramSys)
  ) fix();

  string      preload_elf;
  string      boot_hex;
  logic [1:0] boot_mode;
  logic [1:0] preload_mode;
  bit [31:0]  exit_code;

  initial begin
    // Fetch plusargs or use safe (fail-fast) defaults
    if (!$value$plusargs("BOOTMODE=%d", boot_mode))     boot_mode     = 0;
    if (!$value$plusargs("PRELMODE=%d", preload_mode))  preload_mode  = 3;
    if (!$value$plusargs("BINARY=%s",   preload_elf))   preload_elf   = "";
    if (!$value$plusargs("IMAGE=%s",    boot_hex))      boot_hex      = "";

    // Set boot mode and preload boot image if there is one
    fix.vip.set_boot_mode(boot_mode);
    fix.vip.i2c_eeprom_preload(boot_hex);
    fix.vip.spih_norflash_preload(boot_hex);

    // Wait for reset
    fix.vip.wait_for_reset();

    // Preload in idle mode or wait for completion in autonomous boot
    if (boot_mode == 0) begin
      // Idle boot: preload with the specified mode
      case (preload_mode)
        0: begin      // JTAG
          fix.vip.jtag_init();
          fix.vip.jtag_elf_run(preload_elf);
          fix.vip.jtag_wait_for_eoc(exit_code);
        end 3: begin  // MEMH
          fix.vip.jtag_init();
          fix.vip.jtag_wait_for_llc_config_halt();
          fix.vip.memh_elf_preload(preload_elf);
          fix.vip.jtag_elf_run_no_preload(preload_elf);
          fix.vip.jtag_wait_for_eoc(exit_code);
        end default: begin
          $fatal(1, "Unsupported preload mode %d for LinGo top!", preload_mode);
        end
      endcase
    end else if (boot_mode == 1) begin
      $fatal(1, "Unsupported boot mode %d (SD Card)!", boot_mode);
    end else begin
      // Autonomous boot: Only poll return code
      fix.vip.jtag_init();
      fix.vip.jtag_wait_for_eoc(exit_code);
    end

    // Wait for the UART to finish reading the current byte
    wait (fix.vip.uart_reading_byte == 0);

    $finish;
  end

endmodule
