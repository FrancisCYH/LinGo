package fgramemfp.axi

import chisel3._

/** Write-priority arbitration for a physical SRAM port. */
class SramArbiter extends RawModule {
  val wrvalid = IO(Input(Bool()))
  val wrready = IO(Output(Bool()))
  val rdvalid = IO(Input(Bool()))
  val rdready = IO(Output(Bool()))
  // Supplied by the scratchpad's physical-port decode, including broadcast masks.
  val conflict = IO(Input(Bool()))

  // Writes always have priority, keeping AXI WREADY independent of WVALID.
  wrready := true.B
  rdready := rdvalid && !(wrvalid && conflict)
}
