# Conceptual description

- SM core: warps, per-thread registers, shared memory, L1 cache, CUDA/Tensor-style ALU, SIMT warps scheduled inside each SM
- SM grid: generated 4×4 array of SMs
- L2 cache + arbiter: aggregates requests from all SMs
- HBM/DRAM controllers: channelized external memory
- Host command processor: receives kernel launches and dispatches to all SMs

