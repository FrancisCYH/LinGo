# AXI4 / AXI-Lite 完整接口审查

审查与修复日期：2026-10-11。对象为当前工作区，包含此前完成的 WVALID 误写修复，以及本报告确认的四类问题的修复。默认仿真 RTL 已重新生成并同步。

## 结论

**审查确认的四类错误均已修复。修复后的完整回归为 15 项 PASS、0 项 FAIL、1 项 OBSERVED；修复前的 5 个失败检查全部转为 PASS。**

这些结果覆盖已发现问题及本报告的事务范围，不表示已经完成完整 AXI 形式合规证明。

独立读写、随机背压下的并发普通/广播写、配置区物理端口冲突、扩展地址宽度及高地址读写均已验证。AXI-Lite 控制接口回归通过。单 outstanding、不实现 exclusive、或等待 AW 后接收 W 本身不是违规。

下表和第 1–4 节保留修复前的根因与复现证据，所列行号为审查基线的行号。当前实现及修复后验证见后面的“修复实现与验证结果”。

| 优先级 | 根因 | 影响范围 | 确认证据 |
| --- | --- | --- | --- |
| P1 | ReadEngine 把 SRAM 请求状态与待发送 R 响应混在一起 | 默认配置，读背压叠加同 bank 写入 | 仿真确认 RVALID 撤销；恢复后遗漏一拍 |
| P1 | 广播仲裁把写目标固定当作 bank 0 | 默认配置，广播写与目标 bank 的 AXI 读并发 | 仿真确认 bank 1 返回 X 数据 |
| P2 | 多个配置地址 bank 共用同一 SRAM A 端口，却按地址 bank 仲裁 | 配置区大于单个数据 bank 时 | 8 KiB 配置区仿真确认返回 X 数据 |
| P2 | Scratchpad 地址宽度公式误用了配置容量的对数 | 扩大配置区时 | 64 KiB 配置区生成地址宽度不足；128 KiB 配置区生成失败 |

这里 P1 表示默认接口在合法事务组合下出错；P2 表示非默认参数下的确定错误。

## 审查范围与方法

逐一检查了以下源文件及对应生成 Verilog：

- `axi/Axi4Bundle.scala`、`axi/AxiLiteBundle.scala`：接口字段、方向和可选属性。
- `axi/WriteEngine.scala`、`axi/ReadEngine.scala`：AW/W/B、AR/R 握手、状态、ID、末拍、背压。
- `axi/SramAddrGen.scala`：FIXED、INCR、WRAP 和非对齐首拍地址推进。
- `axi/SramArbiter.scala`、`axi/AxiScratchpad.scala`：数据 bank、配置 SRAM、广播 mask、物理端口冲突和地址译码。
- `dsa/util/SRAM.scala`：同步读延迟、byte mask、非对称端口。
- `LinGoController.scala`：全部 AXI-Lite CSR 读写路径及字节合并。
- `LinGoWithAXI.scala`：总线宽度、时钟、复位及控制器连接。

规范依据：[Arm AMBA AXI and ACE Protocol Specification, IHI 0022H](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)，主要核对 A3.1–A3.4、A7.2、A9、B1。其握手规则要求 VALID 和当前响应信息保持到握手结束；可选信号及实现能力按 A9/B1 判断。

仿真使用 Icarus Verilog，直接测试生成模块的实际 SRAM 端口及数据输出。字节数据由独立地址模型生成，写测试使用独立 byte scoreboard。随机读背压使用固定种子 `0x19adbeef`，部分写掩码使用固定种子 `0x55f01234`，结果可复现。错误事务不使用预期失败豁免：脚本报告 FAIL 并返回非零退出码。

## 1. 待读响应被仲裁撤销，恢复后丢拍

位置：[ReadEngine.scala](src/main/scala/axi/ReadEngine.scala)，第 134–138、110–123、197–204 行。

触发序列：

1. 接收 `ARADDR=0x100, ARLEN=3, ARSIZE=4, ARBURST=INCR`。
2. 第一拍 `RVALID=1`，主机保持 `RREADY=0`，因此 `0x100` 的响应尚未接收。
3. 对同一个物理 bank 的另一个地址 `0x300` 发起单拍写。
4. 写优先仲裁使读引擎 `ready=0`；`s_r_stream` 无条件转入 `s_r_wait`，下一周期撤销 RVALID。

这是明确的握手违规。不能因为 SRAM 不能继续预取，就撤销已经提供给主机的响应。

第二个独立复现允许响应重新出现，再检查数据序列：原本应为 `0x100, 0x110, 0x120, 0x130`，实际接受 `0x100` 后，第二拍已是 `0x120`，跳过了 `0x110`。原因是等待状态重新发读时推进了地址，而输出保持状态还保留着前一拍。

对应失败用例：`read_stall_same_bank_write`、`read_after_stalled_conflict`。

修复方向：将 SRAM 请求/返回和 R 通道响应存储分开，用带 valid 的响应寄存器或队列保存整组 `RDATA/RID/RRESP/RLAST`。仲裁只能阻止新 SRAM 请求；未握手的响应不能被清除或替换。地址、发出请求数和已接受响应数需要分别管理。

## 2. 广播写绕过目标 bank 的读冲突检测

位置：[AxiScratchpad.scala](src/main/scala/axi/AxiScratchpad.scala)，第 155–160、191–210 行。

广播开启后，`arbiter.wr_cs` 被强制为 0。若广播 mask 命中 bank 1，而 AXI 也正在读 bank 1，仲裁器认为访问不同 bank，允许读引擎推进。

实际 bank 1 的 SRAM A 端口被写入占用：地址 mux 选择广播写地址，不能同时执行 AXI 读。因此读引擎返回的数据并不是所请求的读数据。

已复现：`mask=0b10`、bank 1 广播写 beat 地址 `0x30`，同时读取 `ARADDR=0x1100`，写入和读请求使用不同的 SRAM 字地址，避免把同址读写的未定义行为误判为错误。读响应返回 X，独立模型期待已初始化的非零字。

对应失败用例：`broadcast_read_target_bank`。

反方向也有问题：mask 未命中 bank 0 时，读 bank 0 仍可能被无关广播写阻塞，并触发第 1 类问题。此项由代码路径确认，未单独统计仿真失败。

修复方向：按 `bcast_bank_mask(rd_bank)` 判断数据 SRAM 的实际冲突；配置 SRAM 单独处理。需要与第 1 类问题一起修复，单独修改 mask 仍不能保证背压下响应正确。

## 3. 多个配置地址 bank 实际共享一个物理端口

位置：[AxiScratchpad.scala](src/main/scala/axi/AxiScratchpad.scala)，第 38–45、96–99、159–160、231–250 行。

配置 SRAM 比单个数据 bank 大时，代码把它划成多个地址 bank。它们实际上都连接同一块 `spad_last_bank_io`，共享 A 端口。

仲裁器只比较 `wr_csel === rd_csel`，把不同配置地址 bank 视为不同物理存储器。例如 12 个 4 KiB 数据 bank，加 8 KiB 配置 SRAM，配置地址 bank 12 与 13 共享一个 SRAM。

已生成该配置并复现：同时写 `0xD300`、读 `0xC100`，仲裁放行双方，物理端口执行写入，读通道返回 X。

对应失败用例：`config_virtual_bank_conflict`。默认 4 KiB 配置 SRAM只有一个配置地址 bank，不触发这项。

修复方向：物理资源冲突判断应为“数据 bank 相同，或双方都访问配置 SRAM”，而不是仅比较地址 bank 编号。

## 4. 配置 SRAM 容量没有正确进入地址宽度计算

位置：[AxiScratchpad.scala](src/main/scala/axi/AxiScratchpad.scala)，第 33 行。

当前计算为：

```scala
log2Ceil(baseAddr + spadBanksNum * (1 << lgSizeSpadBank) + lgSizeLastBlock - 1)
```

其中 `lgSizeLastBlock` 是容量的 log2，而不是字节容量。容量项应使用 `BigInt(1) << lgSizeLastBlock`，并与顶层的容量计算保持一致。

已验证两组参数：

- 12 × 4 KiB 数据 SRAM，加 64 KiB 配置 SRAM，总地址空间 112 KiB，需要 17 位地址；模块只生成 16 位。部分配置地址无法表示，接到正确宽度的顶层时存在高位截断风险。
- 配置 SRAM 扩为 128 KiB 时，仍算出 16 位地址；生成阶段在第 235/236 行报错：`High index 4 is out of range [0, 3]`，因为配置偏移需要更多位，而地址选择字段仍太窄。

对应失败检查：`large_config_address_width`；128 KiB 变体的生成失败另列为生成验证结果。

## 通过的检查及其边界

| 检查 | 结果 | 覆盖 |
| --- | --- | --- |
| 普通独立读事务矩阵 | PASS，288 组 | 数据 bank 0、1、配置 bank；1/2/4/8/16 字节；FIXED/INCR/WRAP；WRAP 长度 2/4/8/16；最长 256 拍 INCR；非对齐首地址；连续接收及随机背压；有效 byte lane、ID、RLAST、无多余拍、停顿稳定性 |
| 普通独立写事务矩阵 | PASS，360 组 | 同上三类 bank 和传输大小；三种 burst；最长 256 拍 INCR；AW 先、W 先、同时提供；空拍；随机部分 WSTRB 和全零 WSTRB；B 背压；通过 SRAM B 端口读回验证被写及未被写字节 |
| 同 bank 写冲突时恰好接受当前 R 拍 | PASS | 当前 R 拍已握手的定向路径；不代表尚未握手的路径正确 |
| 不同物理数据 bank 并发读写 | PASS | bank 0 写 / bank 1 读的定向路径 |
| AXI 复位中止 | PASS | 待读响应、待写响应、AW 后等待 W；复位后没有遗留响应，重新访问可完成 |
| AXI-Lite | PASS | AW 先、W 先、同时提供；全部默认 CSR 和 12 个广播 base 寄存器；部分/全零 byte strobe；启动命令脉冲及 strobe 门控；B/R 背压；待读响应期间更新同 CSR；复位中止事务和 CSR 清零 |
| 前一轮误写回归 | PASS | 普通、配置和广播 WVALID 空拍；独立 WriteEngine 下游背压；LAST 与 B 响应 |
| Verilator Scratchpad lint | PASS | 未出现 lint 警告；lint 不能检出上面的时序协议错误 |
| Verilator Controller lint | 完成，有警告 | 2058 条位宽警告均位于 `LinGoController.fgra` 数据通路，未出现 AXI-Lite CSR 逻辑警告；不代表整个硬件 lint 无警告 |

修复后读矩阵还检查了无背压 burst 的持续吞吐：第一拍出现后不插入空拍。定向测试允许合法的响应延迟变化，仍要求响应保持、数据顺序、ID 和末拍正确。

基本矩阵没有混入违反主机规范的跨 4 KiB burst、非法 WRAP 长度或超过数据总线宽度的 AxSIZE。这些不能用作证明从机不合规的用例。

288/360 是事务数量，不是形式验证覆盖率。未穷举全部 ID、12 个数据 bank、所有地址、所有并发及 reset 相位组合；ASIC/FPGA SRAM 黑盒未验证。即使以上矩阵通过，也不能替代完整协议 checker、随机并发验证或形式证明。

## 接口限制及设计策略，不能与确定的协议错误混为一谈

1. **一个在途读事务、一个在途写事务是合法的。** 从机用 READY 限制接收数量，不需要支持任意数量 outstanding。
2. **等待 AW 后才接收 W 是合法的。** W 先提供时，主机应保持 VALID 和数据，直到被接收；本实现测试通过。
3. **不实现 exclusive access 是合法的。** 本实现忽略 AxLOCK、返回 OKAY，没有返回 EXOKAY。规范 A7.2.3 允许这种行为，不应把它列为缺陷。
4. **未使用 cache/qos/prot 不是自动违规。** 本实现没有缓存、QoS 或安全属性区分；应在接口说明中明确。
5. **AWLEN/WLAST 不一致缺少防御检查。** WriteEngine 用 WLAST 结束 burst，未核对拍数。合法主机会让 WLAST 与 AWLEN 一致；这一项属于错误输入检测能力，不能直接视作合法 AXI 事务下的错误。
6. **未映射地址被静默处理。** 实测写 `0xE100` 被接收但没有 SRAM bank 命中；读该地址返回 0。BRESP/RRESP 固定 OKAY。固定 OKAY 本身不违反握手协议；应明确地址空洞策略，或增加错误响应，以免软件把丢弃写入误认为成功。
7. **广播是自定义存储访问语义。** 广播地址由各 bank 的 base 与全局 beat counter 决定，忽略 AWADDR 对普通 SRAM 地址的意义。应明确支持的广播访问形式，以及 broadcast CSR 在在途 AXI burst 中能否修改；CSR 当前未按 burst 锁存。
8. **非默认参数还有使用限制。** `baseAddr` 没有用于地址减基址或窗口译码；`hasMask=false` 不支持一般 byte-strobe SRAM 语义；配置 SRAM 小于数据 bank 时，其余配置窗口可能发生截断别名。当前顶层使用 baseAddr=0、hasMask=true、等大小配置 bank，不触发这些限制。这里是静态检查，未增加相应参数仿真。
9. **时钟必须按当前顶层绑定。** 顶层把 Scratchpad 的隐式 clock 与 io.aclk 接到同一时钟；内部 SRAM 与引擎没有跨时钟处理。外部不能把这两个时钟当作独立时钟使用。复位释放应由系统保证同步。
10. **AXI-Lite CSR 当前按精确的 word 地址译码。** 地址表中的 word 对齐访问已验证；未定义的 CSR/非对齐访问会读 0 或忽略写入并返回 OKAY。应在 CSR 访问约定中说明，不把未知访问策略误报为已经完成的内存访问支持。

## 复现

默认 RTL 已在 `simulation/circuits/LinGoWithAXI.v`。生成参数化变体：

```bash
cd hardware
conda run -n lingo sbt \
  'Test/runMain fgramemfp.axi.ScratchpadAuditVerilogGen 13 /tmp/lingo-axi-audit-multicfg' \
  'Test/runMain fgramemfp.axi.ScratchpadAuditVerilogGen 16 /tmp/lingo-axi-audit-largecfg' \
  'Test/runMain fgramemfp.axi.ScratchpadAuditVerilogGen 17 /tmp/lingo-axi-audit-128kcfg'
cd ..
python3 hardware/audit_axi.py simulation/circuits/LinGoWithAXI.v
```

回归脚本：[audit_axi.py](audit_axi.py)。修复前结果：[axi_audit_before_fix.json](axi_audit_before_fix.json)。修复后结果：[axi_audit_results.json](axi_audit_results.json)。当前应报告 15 个 PASS、0 个 FAIL、1 个 OBSERVED。缺少参数化生成文件时，脚本会报告 NOT_RUN 并返回非零退出码，避免跳过所需检查。地址空洞用例报告 OBSERVED，不能计为合规 PASS。

128 KiB 配置区现在应成功生成并通过高地址测试；原来的位宽越界已消除。

## 修复实现与验证结果

1. **读请求与响应分离**：[ReadEngine.scala](src/main/scala/axi/ReadEngine.scala) 使用两槽响应队列。发出 SRAM 请求前，先为返回数据预留一个槽；占用计数同时包含已缓存响应和 SRAM 在途响应。返回的 `RDATA/RID/RRESP/RLAST` 被寄存，后续仲裁不会撤销或改写当前 R 响应。请求地址及剩余请求拍数仅在 SRAM 接受请求时推进。
2. **物理端口仲裁**：[AxiScratchpad.scala](src/main/scala/axi/AxiScratchpad.scala) 计算显式 conflict，交给 [SramArbiter.scala](src/main/scala/axi/SramArbiter.scala)。普通访问按物理数据 bank 或共享配置 SRAM 判断冲突；广播按实际 mask 判断。写优先规则保持，WREADY 不组合依赖 WVALID。读返回 bank 选择仅在读请求被接受时更新。
3. **容量与地址宽度**：地址宽度使用 `BigInt` 字节容量求和，与顶层相同的 exclusive-end 容量计算一致。64 KiB 配置区生成 17 位地址，128 KiB 配置区生成 18 位地址。对 `0x10000` 及配置区最后一拍实际写读，均正确；低地址数据 bank 没有高位截断别名。

验证结果：

| 检查 | 修复后结果 |
| --- | --- |
| 原始读 VALID 撤销、恢复后跳拍 | 两个用例 PASS |
| 原始广播目标 bank 读冲突 | PASS |
| 原始共享配置 SRAM 读写冲突 | PASS |
| 64 KiB 配置区地址宽度 | PASS，17 位 |
| 128 KiB 配置区生成及地址宽度 | PASS，18 位 |
| 64/128 KiB 高地址、末拍、低地址别名 | 两个用例 PASS |
| 288 组独立读事务、360 组独立写事务 | PASS |
| 90 个读 burst 与 90 个普通/广播写 burst 并发，随机读背压 | PASS |
| 原有 AXI-Lite、复位及不同 bank 并发检查 | PASS |
| 前一轮 WriteEngine / SPM 误写回归 | PASS |
| 重新生成默认及 8/64/128 KiB 配置区 RTL | 成功 |
| 修复后 Scratchpad Verilator lint | PASS，无警告 |

**时延变化**：相对修复前，首拍 R 响应增加一个寄存周期，用于隔离 SRAM 返回数据与待握手响应。无仲裁冲突、无背压时，连续 burst 仍可每周期接受并返回一拍；读矩阵已有持续吞吐断言。仍只接受一个在途 AR burst，保留原接口并发能力。

第“接口限制及设计策略”节描述的未映射地址响应、广播访问约定和非默认参数使用限制仍适用；这些不属于本次四类根因的修复范围。没有将定向回归通过表述为整个 AXI 实现已经完成形式合规验证。
