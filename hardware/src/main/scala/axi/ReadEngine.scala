package fgramemfp.axi

import chisel3._
import chisel3.util._

class AXI4RdIntfView(params: AXI4BundleParameters) extends Bundle {
  val ar = Irrevocable(new AXI4BundleAR(params))
  val r = Flipped(Irrevocable(new AXI4BundleR(params)))
}

/** One AXI read burst with a one-cycle SRAM and two response credits. */
class ReadEngine(params: AXI4BundleParameters) extends RawModule {
  val aclk = IO(Input(Clock()))
  val aresetn = IO(Input(Bool()))
  val s_axi = IO(Flipped(new AXI4RdIntfView(params)))

  // A request is issued only on valid && ready. Its data returns one cycle later.
  val ready = IO(Input(Bool()))
  val valid = IO(Output(Bool()))
  val addr = IO(Output(UInt(params.addrBits.W)))
  val data = IO(Input(UInt(params.dataBits.W)))

  withClockAndReset(aclk, (!aresetn).asAsyncReset) {
    val active = RegInit(false.B)
    val burstId = RegInit(0.U(params.idBits.W))
    val burstLen = RegInit(0.U(params.lenBits.W))
    val burstSize = RegInit(0.U(params.sizeBits.W))
    val burstType = RegInit(0.U(params.burstBits.W))
    val requestAddr = RegInit(0.U(params.addrBits.W))
    val nextAddress = SramAddrGen(params.addrBits, requestAddr,
      burstLen, burstSize, burstType)
    // Nine bits are needed to represent all 256 beats of an AXI4 INCR burst.
    val remaining = RegInit(0.U((params.lenBits + 1).W))

    // Count both buffered responses and the SRAM response in flight. Reserving
    // a slot before issuing a read prevents overwriting data under R backpressure.
    val occupied = RegInit(0.U(2.W))
    val responses = Module(new Queue(new AXI4BundleR(params), 2))
    s_axi.r <> responses.io.deq
    val responseAccepted = s_axi.r.fire
    valid := active && remaining =/= 0.U && (occupied < 2.U || responseAccepted)
    addr := requestAddr
    val requestAccepted = valid && ready

    val returning = RegNext(requestAccepted, false.B)
    val returningLast = RegEnable(remaining === 1.U, false.B, requestAccepted)
    responses.io.enq.valid := returning
    responses.io.enq.bits.data := data
    responses.io.enq.bits.id := burstId
    responses.io.enq.bits.resp := 0.U
    responses.io.enq.bits.last := returningLast

    s_axi.ar.ready := !active
    when(s_axi.ar.fire) {
      active := true.B
      burstId := s_axi.ar.bits.id
      burstLen := s_axi.ar.bits.len
      burstSize := s_axi.ar.bits.size
      burstType := s_axi.ar.bits.burst
      requestAddr := s_axi.ar.bits.addr
      remaining := s_axi.ar.bits.len +& 1.U
    }
    when(requestAccepted) {
      remaining := remaining - 1.U
      when(remaining =/= 1.U) {
        requestAddr := nextAddress
      }
    }
    when(requestAccepted =/= responseAccepted) {
      occupied := Mux(requestAccepted, occupied + 1.U, occupied - 1.U)
    }
    when(responseAccepted && s_axi.r.bits.last) {
      active := false.B
    }

    assert(!returning || responses.io.enq.ready, "SRAM read response has no reserved slot")
  }
}
