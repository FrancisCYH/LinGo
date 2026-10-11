package fgramemfp.axi

import chisel3.stage.ChiselStage

// Audit the supported configuration with two virtual config banks sharing one SRAM.
object ScratchpadAuditVerilogGen extends App {
  val cfgLgBytes = args.headOption.map(_.toInt)
    .getOrElse(sys.env.getOrElse("LINGO_AUDIT_CFG_LG", "13").toInt)
  val outputDir = args.lift(1)
    .getOrElse(sys.env.getOrElse("LINGO_OUTPUT_DIR", "/tmp/lingo-axi-audit-multicfg"))
  (new ChiselStage).emitVerilog(
    new AXI4Scratchpad(idWidth = 8, spadBanksNum = 12,
      lgSizeSpadBank = 12,
      lgSizeLastBlock = cfgLgBytes,
      axiBeatBytes = 16, bPortBytes = 4, hasMask = true),
    Array("-td", outputDir))
}
