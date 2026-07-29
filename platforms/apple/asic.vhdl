---------------------------------------------------------------------------
-- Top-level Apple Silicon-style System on Chip
---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity apple_silicon_asic is
    generic (
        NUM_P_CORES : integer := 4;   -- high-performance CPU cores
        NUM_E_CORES : integer := 4;   -- high-efficiency CPU cores
        NUM_GPU_CORES: integer := 8;  -- GPU shader cores
        NNE_WIDTH   : integer := 4;   -- Neural Engine grid size
        DATA_WIDTH  : integer := 32
    );
    port (
        clk_asic : in std_logic;
        rst_asic : in std_logic;

        -- External dynamic random-access memory
        dram_addr  : out std_logic_vector(31 downto 0);
        dram_wdata : out std_logic_vector(DATA_WIDTH-1 downto 0);
        dram_rdata : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        dram_we    : out std_logic;
        dram_valid : out std_logic;
        dram_resp_vld : in std_logic;

        -- Host peripheral / input-output (simplified)
        pcie_rx_data  : in  std_logic_vector(127 downto 0);
        pcie_rx_valid : in  std_logic;
        pcie_tx_data  : out std_logic_vector(127 downto 0);
        pcie_tx_valid : out std_logic
    );
end entity;

architecture conceptual of apple_silicon_asic is

    component compute_core is
        generic (
            CORE_ID        : integer := 0;
            CORE_TYPE      : string(1 to 3) := "CPU";
            NUM_LANES      : integer := 4;
            REG_FILE_DEPTH : integer := 32;
            L1_DEPTH       : integer := 512;
            DATA_WIDTH     : integer := 32
        );
        port (
            clk : in std_logic;
            rst : in std_logic;
            inst_in       : in  std_logic_vector(31 downto 0);
            inst_valid    : in  std_logic;
            inst_ready    : out std_logic;
            fabric_req_addr  : out std_logic_vector(31 downto 0);
            fabric_req_wdata : out std_logic_vector(DATA_WIDTH-1 downto 0);
            fabric_req_we    : out std_logic;
            fabric_req_valid : out std_logic;
            fabric_req_ready : in  std_logic;
            fabric_resp_rdata : in  std_logic_vector(DATA_WIDTH-1 downto 0);
            fabric_resp_valid : in  std_logic;
            interrupt_in  : in  std_logic
        );
    end component;

    -- Total number of fabric masters
    constant TOTAL_CORES : integer := NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + NNE_WIDTH*NNE_WIDTH;

    -- Aggregate fabric request arrays
    type addr_arr_t is array (0 to TOTAL_CORES-1) of std_logic_vector(31 downto 0);
    type data_arr_t is array (0 to TOTAL_CORES-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal fab_req_addr  : addr_arr_t;
    signal fab_req_wdata : data_arr_t;
    signal fab_req_we    : std_logic_vector(TOTAL_CORES-1 downto 0);
    signal fab_req_valid : std_logic_vector(TOTAL_CORES-1 downto 0);
    signal fab_req_ready : std_logic_vector(TOTAL_CORES-1 downto 0);
    signal fab_resp_rdata: data_arr_t;
    signal fab_resp_valid: std_logic_vector(TOTAL_CORES-1 downto 0);

    -- Instruction feeds for each core
    signal inst_data  : std_logic_vector(31 downto 0);
    signal inst_valid : std_logic;

    -- Unified memory
    type mem_t is array (0 to 16383) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal unified_mem : mem_t;

    -- Media engine (fixed-function encode/decode)
    signal media_req_addr  : std_logic_vector(31 downto 0);
    signal media_req_wdata : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal media_req_we    : std_logic;
    signal media_req_valid : std_logic;

    -- Simple command processor / boot controller
    type boot_state_t is (BOOT, RUN);
    signal boot_state : boot_state_t;

begin

    -----------------------------------------------------------------------
    -- 1. Performance CPU cores
    -----------------------------------------------------------------------
    p_cores : for i in 0 to NUM_P_CORES-1 generate
        p_core_inst : compute_core
            generic map (
                CORE_ID        => i,
                CORE_TYPE      => "CPU",
                NUM_LANES      => 1,
                REG_FILE_DEPTH => 64,
                L1_DEPTH       => 1024,
                DATA_WIDTH     => DATA_WIDTH
            )
            port map (
                clk => clk_asic,
                rst => rst_asic,
                inst_in       => inst_data,
                inst_valid    => inst_valid,
                inst_ready    => open,
                fabric_req_addr  => fab_req_addr(i),
                fabric_req_wdata => fab_req_wdata(i),
                fabric_req_we    => fab_req_we(i),
                fabric_req_valid => fab_req_valid(i),
                fabric_req_ready => fab_req_ready(i),
                fabric_resp_rdata=> fab_resp_rdata(i),
                fabric_resp_valid=> fab_resp_valid(i),
                interrupt_in  => '0'
            );
    end generate p_cores;

    -----------------------------------------------------------------------
    -- 2. Efficiency CPU cores
    -----------------------------------------------------------------------
    e_cores : for i in 0 to NUM_E_CORES-1 generate
        e_core_inst : compute_core
            generic map (
                CORE_ID        => NUM_P_CORES + i,
                CORE_TYPE      => "CPU",
                NUM_LANES      => 1,
                REG_FILE_DEPTH => 32,
                L1_DEPTH       => 512,
                DATA_WIDTH     => DATA_WIDTH
            )
            port map (
                clk => clk_asic,
                rst => rst_asic,
                inst_in       => inst_data,
                inst_valid    => inst_valid,
                inst_ready    => open,
                fabric_req_addr  => fab_req_addr(NUM_P_CORES + i),
                fabric_req_wdata => fab_req_wdata(NUM_P_CORES + i),
                fabric_req_we    => fab_req_we(NUM_P_CORES + i),
                fabric_req_valid => fab_req_valid(NUM_P_CORES + i),
                fabric_req_ready => fab_req_ready(NUM_P_CORES + i),
                fabric_resp_rdata=> fab_resp_rdata(NUM_P_CORES + i),
                fabric_resp_valid=> fab_resp_valid(NUM_P_CORES + i),
                interrupt_in  => '0'
            );
    end generate e_cores;

    -----------------------------------------------------------------------
    -- 3. GPU shader cores
    -----------------------------------------------------------------------
    gpu_cores : for i in 0 to NUM_GPU_CORES-1 generate
        gpu_core_inst : compute_core
            generic map (
                CORE_ID        => NUM_P_CORES + NUM_E_CORES + i,
                CORE_TYPE      => "GPU",
                NUM_LANES      => 8,
                REG_FILE_DEPTH => 16,
                L1_DEPTH       => 1024,
                DATA_WIDTH     => DATA_WIDTH
            )
            port map (
                clk => clk_asic,
                rst => rst_asic,
                inst_in       => inst_data,
                inst_valid    => inst_valid,
                inst_ready    => open,
                fabric_req_addr  => fab_req_addr(NUM_P_CORES + NUM_E_CORES + i),
                fabric_req_wdata => fab_req_wdata(NUM_P_CORES + NUM_E_CORES + i),
                fabric_req_we    => fab_req_we(NUM_P_CORES + NUM_E_CORES + i),
                fabric_req_valid => fab_req_valid(NUM_P_CORES + NUM_E_CORES + i),
                fabric_req_ready => fab_req_ready(NUM_P_CORES + NUM_E_CORES + i),
                fabric_resp_rdata=> fab_resp_rdata(NUM_P_CORES + NUM_E_CORES + i),
                fabric_resp_valid=> fab_resp_valid(NUM_P_CORES + NUM_E_CORES + i),
                interrupt_in  => '0'
            );
    end generate gpu_cores;

    -----------------------------------------------------------------------
    -- 4. Neural Engine matrix core grid
    -----------------------------------------------------------------------
    nne_grid : for x in 0 to NNE_WIDTH-1 generate
        nne_row : for y in 0 to NNE_WIDTH-1 generate
            nne_inst : compute_core
                generic map (
                    CORE_ID        => NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x,
                    CORE_TYPE      => "NNE",
                    NUM_LANES      => 4,
                    REG_FILE_DEPTH => 8,
                    L1_DEPTH       => 256,
                    DATA_WIDTH     => DATA_WIDTH
                )
                port map (
                    clk => clk_asic,
                    rst => rst_asic,
                    inst_in       => inst_data,
                    inst_valid    => inst_valid,
                    inst_ready    => open,
                    fabric_req_addr  => fab_req_addr(NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x),
                    fabric_req_wdata => fab_req_wdata(NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x),
                    fabric_req_we    => fab_req_we(NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x),
                    fabric_req_valid => fab_req_valid(NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x),
                    fabric_req_ready => fab_req_ready(NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x),
                    fabric_resp_rdata=> fab_resp_rdata(NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x),
                    fabric_resp_valid=> fab_resp_valid(NUM_P_CORES + NUM_E_CORES + NUM_GPU_CORES + y*NNE_WIDTH + x),
                    interrupt_in  => '0'
                );
        end generate nne_row;
    end generate nne_grid;

    -----------------------------------------------------------------------
    -- 5. Unified coherent fabric / arbiter
    --    Simplified: one outstanding request at a time, no MESI protocol.
    --    Real Apple Silicon uses a full cache-coherent crossbar with snooping.
    -----------------------------------------------------------------------
    fabric : process(clk_asic, rst_asic)
        variable sel : integer range 0 to TOTAL_CORES-1;
    begin
        if rst_asic = '1' then
            fab_req_ready <= (others => '0');
            fab_resp_valid <= (others => '0');
            dram_valid <= '0';
            dram_we <= '0';

        elsif rising_edge(clk_asic) then
            fab_req_ready <= (others => '0');
            fab_resp_valid <= (others => '0');
            dram_valid <= '0';

            -- Pick the lowest-indexed valid request
            sel := 0;
            for i in 0 to TOTAL_CORES-1 loop
                if fab_req_valid(i) = '1' then
                    sel := i;
                end if;
            end loop;

            fab_req_ready(sel) <= '1';

            if fab_req_valid(sel) = '1' then
                -- Direct mapped unified memory
                if fab_req_we(sel) = '1' then
                    unified_mem(to_integer(unsigned(fab_req_addr(sel))) mod 16384) <= fab_req_wdata(sel);
                    dram_addr  <= fab_req_addr(sel);
                    dram_wdata <= fab_req_wdata(sel);
                    dram_we    <= '1';
                    dram_valid <= '1';
                else
                    fab_resp_rdata(sel) <= unified_mem(to_integer(unsigned(fab_req_addr(sel))) mod 16384);
                    fab_resp_valid(sel) <= '1';
                end if;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------
    -- 6. Media engine (fixed-function video encode/decode)
    --    Stub only: feeds memory directly for demonstration.
    -----------------------------------------------------------------------
    media_engine : process(clk_asic, rst_asic)
    begin
        if rst_asic = '1' then
            media_req_valid <= '0';
        elsif rising_edge(clk_asic) then
            media_req_valid <= '0';
            -- Conceptually processes video macroblocks and writes to memory
        end if;
    end process;

    -----------------------------------------------------------------------
    -- 7. Boot / command processor
    --    Feeds instructions to all cores and handles host Peripheral Component Interconnect Express
    -----------------------------------------------------------------------
    boot_cp : process(clk_asic, rst_asic)
    begin
        if rst_asic = '1' then
            boot_state <= BOOT;
            inst_data  <= (others => '0');
            inst_valid <= '0';
            pcie_tx_valid <= '0';
            pcie_tx_data  <= (others => '0');

        elsif rising_edge(clk_asic) then
            inst_valid <= '0';
            pcie_tx_valid <= '0';

            case boot_state is
                when BOOT =>
                    -- In a real chip this would load firmware and kernels from boot ROM.
                    -- Here we broadcast a simple no-operation to keep cores alive.
                    inst_data  <= x"0000_0000";
                    inst_valid <= '1';
                    boot_state <= RUN;

                when RUN =>
                    -- Accept host commands over Peripheral Component Interconnect Express
                    if pcie_rx_valid = '1' then
                        inst_data  <= pcie_rx_data(31 downto 0);
                        inst_valid <= '1';
                        pcie_tx_valid <= '1';
                        pcie_tx_data  <= x"0000_0000_0000_0000_0000_0000_0000_1234";
                    end if;
            end case;
        end if;
    end process;

end architecture;
