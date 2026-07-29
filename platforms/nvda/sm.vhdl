library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Conceptual CUDA core: one Streaming Multiprocessor (SM).
-- The SM is a SIMT engine: it schedules warps, each warp has multiple threads.
entity sm_core is
    generic (
        SM_ID          : integer := 0;
        THREADS_PER_WARP : integer := 8;   -- real GPU = 32, kept small for clarity
        WARPS_PER_SM   : integer := 4;      -- number of warps in this SM
        REGS_PER_THREAD: integer := 16;     -- register file depth per thread
        SHARED_MEM_DEPTH: integer := 1024;  -- ~4 KB if 32-bit (real SM = up to ~228 KB)
        L1_CACHE_DEPTH : integer := 512;    -- small conceptual L1
        DATA_WIDTH     : integer := 32
    );
    port (
        clk : in std_logic;
        rst : in std_logic;

        -- Kernel launch from host/command processor
        kernel_start  : in std_logic;
        kernel_pc     : in std_logic_vector(15 downto 0);
        kernel_done   : out std_logic;

        -- Memory interface to L2 (simplified: one outstanding request)
        l2_req_addr  : out std_logic_vector(31 downto 0);
        l2_req_wdata : out std_logic_vector(DATA_WIDTH-1 downto 0);
        l2_req_we    : out std_logic;
        l2_req_valid : out std_logic;
        l2_req_ready : in  std_logic;

        l2_resp_rdata : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        l2_resp_valid : in  std_logic
    );
end entity;

architecture conceptual of sm_core is

    -----------------------------------------------------------------------
    -- 1. SIMT state: warps, threads, registers
    -----------------------------------------------------------------------
    type reg_file_t is array (0 to WARPS_PER_SM*THREADS_PER_WARP*REGS_PER_THREAD-1)
                       of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal reg_file : reg_file_t;

    -- Per-warp state
    type warp_pc_t   is array (0 to WARPS_PER_SM-1) of unsigned(15 downto 0);
    type warp_active_t is array (0 to WARPS_PER_SM-1) of std_logic;
    signal warp_pc     : warp_pc_t;
    signal warp_active : warp_active_t;
    signal warp_done   : std_logic_vector(WARPS_PER_SM-1 downto 0);

    -- Shared memory / L1 data cache
    type sram_t is array (0 to SHARED_MEM_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    type cache_t is array (0 to L1_CACHE_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal shared_mem : sram_t;
    signal l1_cache   : cache_t;

    -- Simple instruction register (fetched by command processor in real GPU)
    signal instr : std_logic_vector(31 downto 0);

    -- Scheduler state
    signal current_warp : integer range 0 to WARPS_PER_SM-1;
    signal busy         : std_logic;

    -- Instruction fields (conceptual encoding)
    alias op   : std_logic_vector(3 downto 0) is instr(31 downto 28);
    alias rd   : std_logic_vector(3 downto 0) is instr(27 downto 24);
    alias rs1  : std_logic_vector(3 downto 0) is instr(23 downto 20);
    alias imm  : std_logic_vector(15 downto 0) is instr(15 downto 0);

    -- Memory request buffer
    signal mem_req_pending : std_logic;

begin

    -----------------------------------------------------------------------
    -- 2. Warp scheduler + SIMT execution FSM
    -----------------------------------------------------------------------
    scheduler : process(clk, rst)
        variable tid_base : integer;
        variable reg_idx  : integer;
        variable addr     : integer;
        variable result   : std_logic_vector(DATA_WIDTH-1 downto 0);
    begin
        if rst = '1' then
            for w in 0 to WARPS_PER_SM-1 loop
                warp_pc(w)     <= (others => '0');
                warp_active(w) <= '0';
                warp_done(w)   <= '0';
            end loop;
            current_warp   <= 0;
            busy           <= '0';
            kernel_done    <= '0';
            l2_req_valid   <= '0';
            mem_req_pending<= '0';

        elsif rising_edge(clk) then
            l2_req_valid <= '0'; -- default

            if kernel_start = '1' and busy = '0' then
                -- Launch all warps at the kernel PC
                for w in 0 to WARPS_PER_SM-1 loop
                    warp_pc(w)     <= unsigned(kernel_pc) + w; -- staggered start
                    warp_active(w) <= '1';
                    warp_done(w)   <= '0';
                end loop;
                busy <= '1';
                kernel_done <= '0';
                current_warp <= 0;

            elsif busy = '1' then
                -- Round-robin pick a ready warp
                current_warp <= (current_warp + 1) mod WARPS_PER_SM;
                instr <= std_logic_vector(warp_pc(current_warp)) & x"0000_0001";

                if warp_active(current_warp) = '1' then
                    tid_base := current_warp * THREADS_PER_WARP * REGS_PER_THREAD;

                    case op is
                        -- ALU: scalar/vector op across all threads in warp
                        when x"1" => -- ADD
                            for t in 0 to THREADS_PER_WARP-1 loop
                                reg_idx := tid_base + t*REGS_PER_THREAD + to_integer(unsigned(rd));
                                reg_file(reg_idx) <= std_logic_vector(
                                    unsigned(reg_file(tid_base + t*REGS_PER_THREAD + to_integer(unsigned(rs1))))
                                    + unsigned(imm));
                            end loop;
                            warp_pc(current_warp) <= warp_pc(current_warp) + 1;

                        -- LOAD from shared memory
                        when x"2" =>
                            addr := to_integer(unsigned(imm)) mod SHARED_MEM_DEPTH;
                            for t in 0 to THREADS_PER_WARP-1 loop
                                reg_idx := tid_base + t*REGS_PER_THREAD + to_integer(unsigned(rd));
                                reg_file(reg_idx) <= shared_mem((addr + t) mod SHARED_MEM_DEPTH);
                            end loop;
                            warp_pc(current_warp) <= warp_pc(current_warp) + 1;

                        -- STORE to shared memory
                        when x"3" =>
                            addr := to_integer(unsigned(imm)) mod SHARED_MEM_DEPTH;
                            for t in 0 to THREADS_PER_WARP-1 loop
                                reg_idx := tid_base + t*REGS_PER_THREAD + to_integer(unsigned(rs1));
                                shared_mem((addr + t) mod SHARED_MEM_DEPTH) <= reg_file(reg_idx);
                            end loop;
                            warp_pc(current_warp) <= warp_pc(current_warp) + 1;

                        -- GLOBAL LOAD: memory access that goes to L2 (and beyond)
                        when x"4" =>
                            if mem_req_pending = '0' then
                                l2_req_addr  <= std_logic_vector(resize(unsigned(imm) & x"0000", 32));
                                l2_req_we    <= '0';
                                l2_req_valid <= '1';
                                mem_req_pending <= '1';
                            elsif l2_req_ready = '1' then
                                mem_req_pending <= '0';
                                warp_pc(current_warp) <= warp_pc(current_warp) + 1;
                            end if;

                        -- GLOBAL STORE
                        when x"5" =>
                            if mem_req_pending = '0' then
                                l2_req_addr  <= std_logic_vector(resize(unsigned(imm) & x"0000", 32));
                                l2_req_wdata <= reg_file(tid_base + to_integer(unsigned(rs1))*REGS_PER_THREAD);
                                l2_req_we    <= '1';
                                l2_req_valid <= '1';
                                mem_req_pending <= '1';
                            elsif l2_req_ready = '1' then
                                mem_req_pending <= '0';
                                warp_pc(current_warp) <= warp_pc(current_warp) + 1;
                            end if;

                        -- Tensor core matmul: very simplified outer-product step
                        when x"6" =>
                            -- Conceptually accumulate A*B into an accumulator register
                            for t in 0 to THREADS_PER_WARP-1 loop
                                reg_idx := tid_base + t*REGS_PER_THREAD + to_integer(unsigned(rd));
                                result := std_logic_vector(
                                    unsigned(reg_file(reg_idx))
                                    + (unsigned(reg_file(tid_base + t*REGS_PER_THREAD + 0))
                                       * unsigned(reg_file(tid_base + t*REGS_PER_THREAD + 1))));
                                reg_file(reg_idx) <= result;
                            end loop;
                            warp_pc(current_warp) <= warp_pc(current_warp) + 1;

                        -- EXIT warp
                        when x"F" =>
                            warp_active(current_warp) <= '0';
                            warp_done(current_warp) <= '1';

                        when others =>
                            warp_pc(current_warp) <= warp_pc(current_warp) + 1;
                    end case;
                end if;

                -- Completion check
                if unsigned(warp_done) = (WARPS_PER_SM-1 downto 0 => '1') then
                    busy <= '0';
                    kernel_done <= '1';
                end if;
            end if;

            -- Capture L2 response into registers
            if l2_resp_valid = '1' then
                reg_file(current_warp*THREADS_PER_WARP*REGS_PER_THREAD) <= l2_resp_rdata;
            end if;
        end if;
    end process;

end architecture;
