= Mesh of Tensix Cores
- Compute mesh: a generated 2D array of Tensix cores.
- NoC interconnect: explicit wiring of neighbor outputs to inputs; boundaries tied to I/O.
- Memory controllers: aggregate per-core DRAM requests and drive external channels.
- Host/PCIe bridge: converts host commands into NoC packets injected at the mesh edge.
- Boot control: a tiny state machine that brings the chip out of reset.
- Simplifications to be aware of:
  - Real chips have hundreds of cores, not 4×4.
  - The NoC is much more than direct wiring: it has routers, virtual channels, credit-based flow control, and multicast.
  - DRAM controllers are usually high-bandwidth HBM2e/HBM3 PHYs, not simple aggregators.
  - There is normally a separate management/NoC configuration network, a clock/reset/power controller, and sometimes a host CPU complex on-die.
 
