package fgramemfp.axi

import chisel3.stage.ChiselStage

// Generate the engine independently so top-level constant propagation cannot
// remove its SRAM backpressure input from the regression under test.
object WriteEngineVerilogGen extends App {
  (new ChiselStage).emitVerilog(
    new WriteEngine(new AXI4BundleParameters(addrBits = 16, dataBits = 128, idBits = 8)),
    Array("-td", sys.env.getOrElse("LINGO_OUTPUT_DIR", "verilog")))
}
