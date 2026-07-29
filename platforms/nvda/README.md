# NVIDIA graphics processing unit architecture

The NVIDIA device is a coprocessor connected to a host central processing unit over Peripheral Component Interconnect Express. The host runs a driver, the CUDA runtime, and user applications. When the host wants to run something on the graphics processing unit, it launches a kernel, which is a function that will execute across many parallel threads on the graphics processing unit.

The graphics processing unit contains many Streaming Multiprocessors, which are the main compute blocks. A modern chip can have tens to hundreds of Streaming Multiprocessors. Each Streaming Multiprocessor contains many CUDA cores for scalar floating-point and integer operations, Tensor cores for matrix operations, register files for thousands of threads, an L1 data cache, and a configurable block of shared memory. Shared memory is fast static random-access memory that is visible to all threads in the same thread block and is programmed explicitly, while the L1 cache is automatic.

Instructions are consumed by hardware schedulers. A kernel is launched as a grid of thread blocks. Each thread block is assigned to one Streaming Multiprocessor. Inside a Streaming Multiprocessor, threads are grouped into warps of 32 threads. The hardware warp scheduler picks ready warps and issues one instruction per warp per cycle to the execution units. All 32 threads in the warp execute the same instruction in lockstep on different data. This is called Single Instruction Multiple Thread execution. If threads in the same warp take different branches, the hardware masks them off and runs each path separately, which hurts performance.

Memory is unified and cache-based. There is a large pool of high-bandwidth dynamic random-access memory, usually High Bandwidth Memory, shared by the whole chip. Each Streaming Multiprocessor has its own L1 data cache and shared memory. There is also a larger L2 cache shared by all Streaming Multiprocessors. When a thread does a global load or store, the address goes through the L1 cache, then the L2 cache, and finally the High Bandwidth Memory if the data is not cached. The hardware handles coalescing, which means combining memory accesses from threads in the same warp into as few cache lines as possible. Programmers do not manage this explicitly, although they can optimize for it.

Communication between thread blocks is mostly through global memory, which is the High Bandwidth Memory. Threads can also use shared memory within a thread block, which is much faster. For synchronization, there are explicit barriers at the thread-block level, called syncthreads in CUDA, and device-wide events and streams for ordering kernel launches. Kernels are launched asynchronously from the host, meaning the host central processing unit can do other work while the graphics processing unit runs, but the host must call an explicit synchronization function if it needs the results before continuing.

For software engineers, the main programming interface is CUDA C++ or higher-level frameworks. The programmer writes kernels that run on individual threads and relies on the runtime to distribute thread blocks across Streaming Multiprocessors. The programmer controls how threads are grouped into blocks, how much shared memory to use, and how memory is accessed, but the hardware handles scheduling, caching, and memory coalescing automatically.

The key hardware takeaway is that performance depends on keeping the Single Instruction Multiple Thread execution units busy and making memory accesses coalesced and cache-friendly. Unlike Tenstorrent, the graphics processing unit hides latency with massive multithreading rather than with compiler-managed spatial placement. Memory is a global address space with automatic caches, not a collection of explicitly routed scratchpads.

## Conceptual description

- SM core: warps, per-thread registers, shared memory, L1 cache, CUDA/Tensor-style ALU, SIMT warps scheduled inside each SM
- SM grid: generated 4×4 array of SMs
- L2 cache + arbiter: aggregates requests from all SMs
- HBM/DRAM controllers: channelized external memory
- Host command processor: receives kernel launches and dispatches to all SMs

