---------------------------------------------------------------------------
-- Top-level GPU ASIC: 4x4 SM mesh + L2 cache + HBM controllers + host I/F
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cuda_gpu_asic is
    generic (
        GRID_X     : integer := 4;    -- SMs horizontally
        GRID_Y     : integer := 4;    -- SMs vertically
        DATA_WIDTH : integer := 32;
        L2_DEPTH   : integer := 8192; -- small conceptual L2
        DRAM_CHANNELS : integer := 4
    );
    port (
        clk_asic : in std_logic;
        rst_asic : in std_logic;

        -- Host/PCIe front-end
        host_cmd_valid : in  std_logic;
        host_cmd_data  : in  std_logic_vector(127 downto 0);
        host_cmd_ready : out std_logic;
        host_resp_valid: out std_logic;
        host_resp_data : out std_logic_vector(127 downto 0);

        -- External HBM/DRAM
        dram_addr  : out std_logic_vector(DRAM_CHANNELS*32-1 downto 0);
        dram_wdata : out std_logic_vector(DRAM_CHANNELS*DATA_WIDTH-1 downto 0);
        dram_rdata : in  std_logic_vector(DRAM_CHANNELS*DATA_WIDTH-1 downto 0);
        dram_we    : out std_logic_vector(DRAM_CHANNELS-1 downto 0);
        dram_valid : out std_logic_vector(DRAM_CHANNELS-1 downto 0);
        dram_resp_vld : in std_logic_vector(DRAM_CHANNELS-1 downto 0)
    );
end entity;

architecture conceptual of cuda_gpu_asic is

    component sm_core is
        generic (
            SM_ID          : integer := 0;
            THREADS_PER_WARP : integer := 8;
            WARPS_PER_SM   : integer := 4;
            REGS_PER_THREAD: integer := 16;
            SHARED_MEM_DEPTH: integer := 1024;
            L1_CACHE_DEPTH : integer := 512;
            DATA_WIDTH     : integer := 32
        );
        port (
            clk : in std_logic;
            rst : in std_logic;
            kernel_start  : in std_logic;
            kernel_pc     : in std_logic_vector(15 downto 0);
            kernel_done   : out std_logic;
            l2_req_addr  : out std_logic_vector(31 downto 0);
            l2_req_wdata : out std_logic_vector(DATA_WIDTH-1 downto 0);
            l2_req_we    : out std_logic;
            l2_req_valid : out std_logic;
            l2_req_ready : in  std_logic;
            l2_resp_rdata : in  std_logic_vector(DATA_WIDTH-1 downto 0);
            l2_resp_valid : in  std_logic
        );
    end component;

    -- Aggregated SM request interface
    type addr_arr_t is array (0 to GRID_X*GRID_Y-1) of std_logic_vector(31 downto 0);
    type data_arr_t is array (0 to GRID_X*GRID_Y-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sm_req_addr  : addr_arr_t;
    signal sm_req_wdata : data_arr_t;
    signal sm_req_we    : std_logic_vector(GRID_X*GRID_Y-1 downto 0);
    signal sm_req_valid : std_logic_vector(GRID_X*GRID_Y-1 downto 0);
    signal sm_req_ready : std_logic_vector(GRID_X*GRID_Y-1 downto 0);

    signal sm_resp_rdata: data_arr_t;
    signal sm_resp_valid: std_logic_vector(GRID_X*GRID_Y-1 downto 0);

    -- L2 cache
    type l2_t is array (0 to L2_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal l2_cache : l2_t;

    -- Launch distribution
    signal kernel_start_vec : std_logic_vector(GRID_X*GRID_Y-1 downto 0);
    signal kernel_done_vec  : std_logic_vector(GRID_X*GRID_Y-1 downto 0);
    signal kernel_pc        : std_logic_vector(15 downto 0);

    -- Command processor state
    type cmd_state_t is (IDLE, DISPATCH, RUNNING, DONE);
    signal cmd_state : cmd_state_t;

begin

    -----------------------------------------------------------------------
    -- 1. Generate the 4x4 SM grid
    -----------------------------------------------------------------------
    sm_grid : for x in 0 to GRID_X-1 generate
        sm_row : for y in 0 to GRID_Y-1 generate
            sm_inst : sm_core
                generic map (
                    SM_ID           => x + y*GRID_X,
                    THREADS_PER_WARP=> 8,
                    WARPS_PER_SM    => 4,
                    REGS_PER_THREAD => 16,
                    SHARED_MEM_DEPTH=> 1024,
                    L1_CACHE_DEPTH  => 512,
                    DATA_WIDTH      => DATA_WIDTH
                )
                port map (
                    clk => clk_asic,
                    rst => rst_asic,
                    kernel_start  => kernel_start_vec(x + y*GRID_X),
                    kernel_pc     => kernel_pc,
                    kernel_done   => kernel_done_vec(x + y*GRID_X),
                    l2_req_addr   => sm_req_addr(x + y*GRID_X),
                    l2_req_wdata  => sm_req_wdata(x + y*GRID_X),
                    l2_req_we     => sm_req_we(x + y*GRID_X),
                    l2_req_valid  => sm_req_valid(x + y*GRID_X),
                    l2_req_ready  => sm_req_ready(x + y*GRID_X),
                    l2_resp_rdata => sm_resp_rdata(x + y*GRID_X),
                    l2_resp_valid => sm_resp_valid(x + y*GRID_X)
                );
        end generate sm_row;
    end generate sm_grid;

    -----------------------------------------------------------------------
    -- 2. Crossbar/L2 arbiter (simplified)
    --    Real GPUs use a full L2 cache crossbar with multiple partitions.
    -----------------------------------------------------------------------
    l2_arbiter : process(clk_asic, rst_asic)
        variable sm_sel : integer range 0 to GRID_X*GRID_Y-1;
        variable hit    : std_logic;
    begin
        if rst_asic = '1' then
            sm_req_ready <= (others => '0');
            sm_resp_rdata <= (others => (others => '0'));
            sm_resp_valid <= (others => '0');
            dram_valid <= (others => '0');
            dram_we    <= (others => '0');

        elsif rising_edge(clk_asic) then
            sm_req_ready <= (others => '0');
            sm_resp_valid <= (others => '0');
            dram_valid <= (others => '0');

            -- Round-robin pick a requesting SM
            sm_sel := 0;
            for i in 0 to GRID_X*GRID_Y-1 loop
                if sm_req_valid(i) = '1' then
                    sm_sel := i;
                end if;
            end loop;

            sm_req_ready(sm_sel) <= '1';

            -- Very simple direct-mapped L2 concept
            if sm_req_valid(sm_sel) = '1' then
                if sm_req_we(sm_sel) = '1' then
                    -- Write-through to L2 and DRAM
                    l2_cache(to_integer(unsigned(sm_req_addr(sm_sel))) mod L2_DEPTH)
                        <= sm_req_wdata(sm_sel);
                    dram_addr((sm_sel mod DRAM_CHANNELS)*32 + 31 downto (sm_sel mod DRAM_CHANNELS)*32)
                        <= sm_req_addr(sm_sel);
                    dram_wdata((sm_sel mod DRAM_CHANNELS)*DATA_WIDTH + DATA_WIDTH-1 downto (sm_sel mod DRAM_CHANNELS)*DATA_WIDTH)
                        <= sm_req_wdata(sm_sel);
                    dram_we(sm_sel mod DRAM_CHANNELS) <= '1';
                    dram_valid(sm_sel mod DRAM_CHANNELS) <= '1';
                else
                    -- Read
                    sm_resp_rdata(sm_sel)
                        <= l2_cache(to_integer(unsigned(sm_req_addr(sm_sel))) mod L2_DEPTH);
                    sm_resp_valid(sm_sel) <= '1';
                end if;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------
    -- 3. Host command processor (conceptual)
    --    Receives kernel launch commands and broadcasts them to all SMs.
    -----------------------------------------------------------------------
    cmd_proc : process(clk_asic, rst_asic)
    begin
        if rst_asic = '1' then
            cmd_state <= IDLE;
            host_cmd_ready <= '1';
            host_resp_valid <= '0';
            host_resp_data  <= (others => '0');
            kernel_start_vec <= (others => '0');
            kernel_pc <= (others => '0');

        elsif rising_edge(clk_asic) then
            kernel_start_vec <= (others => '0');
            host_resp_valid <= '0';

            case cmd_state is
                when IDLE =>
                    if host_cmd_valid = '1' then
                        kernel_pc <= host_cmd_data(15 downto 0);
                        cmd_state <= DISPATCH;
                    end if;

                when DISPATCH =>
                    -- Start all SMs
                    kernel_start_vec <= (others => '1');
                    cmd_state <= RUNNING;

                when RUNNING =>
                    -- Wait for all SMs to finish
                    if unsigned(kernel_done_vec) = (GRID_X*GRID_Y-1 downto 0 => '1') then
                        cmd_state <= DONE;
                    end if;

                when DONE =>
                    host_resp_valid <= '1';
                    host_resp_data  <= x"0000_0000_0000_0000_0000_0000_0000_BEEF";
                    cmd_state <= IDLE;

                when others =>
                    cmd_state <= IDLE;
            end case;
        end if;
    end process;

end architecture;
