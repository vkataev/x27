library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Conceptual top-level SoC: a 2D Tensix mesh with DRAM and host interfaces.
entity tensix_mesh_asic is
    generic (
        GRID_X       : integer := 4;     -- number of cores horizontally
        GRID_Y       : integer := 4;     -- number of cores vertically
        FLIT_WIDTH   : integer := 56;    -- matches tensix_core noc flit width
        DATA_WIDTH   : integer := 32;
        ADDR_WIDTH   : integer := 16;
        DRAM_CHANNELS: integer := 4      -- one per chip edge side
    );
    port (
        clk_asic  : in std_logic;
        rst_asic  : in std_logic;

        -- Host/PCIe-like interface (simplified)
        pcie_rx_valid : in  std_logic;
        pcie_rx_data  : in  std_logic_vector(127 downto 0);
        pcie_tx_valid : out std_logic;
        pcie_tx_data  : out std_logic_vector(127 downto 0);

        -- External DRAM/HBM interfaces (one channel per side)
        dram_addr     : out std_logic_vector(DRAM_CHANNELS*ADDR_WIDTH-1 downto 0);
        dram_wdata    : out std_logic_vector(DRAM_CHANNELS*DATA_WIDTH-1 downto 0);
        dram_rdata    : in  std_logic_vector(DRAM_CHANNELS*DATA_WIDTH-1 downto 0);
        dram_we       : out std_logic_vector(DRAM_CHANNELS-1 downto 0);
        dram_valid    : out std_logic_vector(DRAM_CHANNELS-1 downto 0);
        dram_resp_vld : in  std_logic_vector(DRAM_CHANNELS-1 downto 0)
    );
end entity;

architecture conceptual of tensix_mesh_asic is

    -----------------------------------------------------------------------
    -- Component declaration for the Tensix core from the previous example.
    -----------------------------------------------------------------------
    component tensix_core is
        generic (
            CORE_X     : integer := 0;
            CORE_Y     : integer := 0;
            SRAM_DEPTH : integer := 4096;
            DATA_WIDTH : integer := 32;
            SIMD_LANES : integer := 16;
            FLIT_WIDTH : integer := 56;
            ADDR_WIDTH : integer := 16
        );
        port (
            clk : in std_logic;
            rst : in std_logic;

            noc_in_n  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);
            noc_in_s  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);
            noc_in_e  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);
            noc_in_w  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);

            noc_out_n : out std_logic_vector(FLIT_WIDTH-1 downto 0);
            noc_out_s : out std_logic_vector(FLIT_WIDTH-1 downto 0);
            noc_out_e : out std_logic_vector(FLIT_WIDTH-1 downto 0);
            noc_out_w : out std_logic_vector(FLIT_WIDTH-1 downto 0);

            dram_req_addr   : out std_logic_vector(ADDR_WIDTH-1 downto 0);
            dram_req_wdata  : out std_logic_vector(DATA_WIDTH-1 downto 0);
            dram_req_we     : out std_logic;
            dram_req_valid  : out std_logic;
            dram_resp_rdata : in  std_logic_vector(DATA_WIDTH-1 downto 0);
            dram_resp_valid : in  std_logic
        );
    end component;

    -----------------------------------------------------------------------
    -- Types for the mesh wiring
    -----------------------------------------------------------------------
    type noc_mesh_t is array (0 to GRID_X-1, 0 to GRID_Y-1) of std_logic_vector(FLIT_WIDTH-1 downto 0);

    -- Per-core outputs; inputs will be derived from neighbor outputs.
    signal noc_n_out : noc_mesh_t;
    signal noc_s_out : noc_mesh_t;
    signal noc_e_out : noc_mesh_t;
    signal noc_w_out : noc_mesh_t;

    -- Derived inputs to each core
    signal noc_n_in  : noc_mesh_t;
    signal noc_s_in  : noc_mesh_t;
    signal noc_e_in  : noc_mesh_t;
    signal noc_w_in  : noc_mesh_t;

    -- Each core's explicit DRAM request
    type dram_addr_arr_t is array (0 to GRID_X-1, 0 to GRID_Y-1) of std_logic_vector(ADDR_WIDTH-1 downto 0);
    type dram_data_arr_t is array (0 to GRID_X-1, 0 to GRID_Y-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal dram_req_addr  : dram_addr_arr_t;
    signal dram_req_wdata : dram_data_arr_t;
    signal dram_req_we    : std_logic_vector(GRID_X*GRID_Y-1 downto 0);
    signal dram_req_valid : std_logic_vector(GRID_X*GRID_Y-1 downto 0);
    signal dram_resp_rdata: dram_data_arr_t;
    signal dram_resp_valid: std_logic_vector(GRID_X*GRID_Y-1 downto 0);

    -- Host bridge -> mesh injection signals (we attach host to core (0,0) West side)
    signal host_to_mesh : std_logic_vector(FLIT_WIDTH-1 downto 0);
    signal mesh_to_host : std_logic_vector(FLIT_WIDTH-1 downto 0);

    -- Boot/control registers (simplified)
    signal boot_done : std_logic;

begin

    -----------------------------------------------------------------------
    -- 1. NoC interconnection: wire neighbor outputs to inputs
    --    Also tie off boundary edges to host / memory controllers.
    -----------------------------------------------------------------------
    interconnect : process(noc_n_out, noc_s_out, noc_e_out, noc_w_out, host_to_mesh)
    begin
        for x in 0 to GRID_X-1 loop
            for y in 0 to GRID_Y-1 loop

                -- NORTH input: from core above, or from a memory controller at top edge
                if y < GRID_Y-1 then
                    noc_n_in(x, y) <= noc_s_out(x, y+1);
                else
                    -- Top edge connected to a memory controller (conceptual)
                    noc_n_in(x, y) <= (others => '0');
                end if;

                -- SOUTH input: from core below, or from a memory controller at bottom edge
                if y > 0 then
                    noc_s_in(x, y) <= noc_n_out(x, y-1);
                else
                    -- Bottom edge connected to a memory controller
                    noc_s_in(x, y) <= (others => '0');
                end if;

                -- EAST input: from core to the right, or host/DRAM at right edge
                if x < GRID_X-1 then
                    noc_e_in(x, y) <= noc_w_out(x+1, y);
                else
                    -- Right edge
                    noc_e_in(x, y) <= (others => '0');
                end if;

                -- WEST input: from core to the left, or host bridge at (0,*)
                if x > 0 then
                    noc_w_in(x, y) <= noc_e_out(x-1, y);
                elsif x = 0 then
                    -- Host bridge injects commands/data into the mesh at the west edge
                    noc_w_in(x, y) <= host_to_mesh;
                else
                    noc_w_in(x, y) <= (others => '0');
                end if;

            end loop;
        end loop;
    end process;

    -----------------------------------------------------------------------
    -- 2. Generate the 2D mesh of Tensix cores
    -----------------------------------------------------------------------
    mesh_gen : for x in 0 to GRID_X-1 generate
        row_gen : for y in 0 to GRID_Y-1 generate
            core_inst : tensix_core
                generic map (
                    CORE_X => x,
                    CORE_Y => y,
                    SRAM_DEPTH => 4096,
                    DATA_WIDTH => DATA_WIDTH,
                    SIMD_LANES => 16,
                    FLIT_WIDTH => FLIT_WIDTH,
                    ADDR_WIDTH => ADDR_WIDTH
                )
                port map (
                    clk => clk_asic,
                    rst => rst_asic,

                    noc_in_n  => noc_n_in(x, y),
                    noc_in_s  => noc_s_in(x, y),
                    noc_in_e  => noc_e_in(x, y),
                    noc_in_w  => noc_w_in(x, y),

                    noc_out_n => noc_n_out(x, y),
                    noc_out_s => noc_s_out(x, y),
                    noc_out_e => noc_e_out(x, y),
                    noc_out_w => noc_w_out(x, y),

                    dram_req_addr   => dram_req_addr(x, y),
                    dram_req_wdata  => dram_req_wdata(x, y),
                    dram_req_we     => dram_req_we(x + y*GRID_X),
                    dram_req_valid  => dram_req_valid(x + y*GRID_X),
                    dram_resp_rdata => dram_resp_rdata(x, y),
                    dram_resp_valid => dram_resp_valid(x + y*GRID_X)
                );
        end generate row_gen;
    end generate mesh_gen;

    -----------------------------------------------------------------------
    -- 3. Memory controllers (conceptual)
    --    Aggregate requests from the edge cores and issue them to DRAM.
    --    In reality there are multiple high-bandwidth HBM controllers.
    -----------------------------------------------------------------------
    mem_ctrl : process(clk_asic, rst_asic)
        variable v_addr  : std_logic_vector(ADDR_WIDTH-1 downto 0);
        variable v_wdata : std_logic_vector(DATA_WIDTH-1 downto 0);
        variable v_we    : std_logic;
        variable v_valid : std_logic;
    begin
        if rst_asic = '1' then
            dram_addr <= (others => '0');
            dram_wdata <= (others => '0');
            dram_we   <= (others => '0');
            dram_valid<= (others => '0');
            dram_resp_rdata <= (others => '0'); -- flatten later below
            dram_resp_valid <= (others => '0');
            boot_done <= '0';

        elsif rising_edge(clk_asic) then
            -- Simple round-robin-ish aggregation: just take a request from
            -- an arbitrary core and forward it. Real controllers have full crossbars.
            v_valid := '0';
            for i in 0 to GRID_X*GRID_Y-1 loop
                if dram_req_valid(i) = '1' and v_valid = '0' then
                    v_addr  := dram_req_addr(i mod GRID_X, i / GRID_X);
                    v_wdata := dram_req_wdata(i mod GRID_X, i / GRID_X);
                    v_we    := dram_req_we(i);
                    v_valid := '1';

                    -- Distribute across 4 DRAM channels by address bits
                    dram_addr((i mod DRAM_CHANNELS)*ADDR_WIDTH + ADDR_WIDTH-1 downto (i mod DRAM_CHANNELS)*ADDR_WIDTH)
                        <= v_addr;
                    dram_wdata((i mod DRAM_CHANNELS)*DATA_WIDTH + DATA_WIDTH-1 downto (i mod DRAM_CHANNELS)*DATA_WIDTH)
                        <= v_wdata;
                    dram_we(i mod DRAM_CHANNELS)   <= v_we;
                    dram_valid(i mod DRAM_CHANNELS)<= '1';
                end if;
            end loop;

            -- Return fake data to all requesters after one cycle (for simulation)
            for i in 0 to GRID_X*GRID_Y-1 loop
                dram_resp_rdata(i mod GRID_X, i / GRID_X) <= dram_rdata((i mod DRAM_CHANNELS)*DATA_WIDTH + DATA_WIDTH-1
                                                                           downto (i mod DRAM_CHANNELS)*DATA_WIDTH);
                dram_resp_valid(i) <= dram_resp_vld(i mod DRAM_CHANNELS);
            end loop;

            -- Boot done after a few cycles (simplified)
            if rst_asic = '0' then
                boot_done <= '1';
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------
    -- 4. Host / PCIe bridge (conceptual)
    --    Translates host commands into NoC packets destined for core (0,0)
    --    or into configuration writes broadcast to the mesh.
    -----------------------------------------------------------------------
    host_bridge : process(clk_asic, rst_asic)
        variable pkt : std_logic_vector(FLIT_WIDTH-1 downto 0);
    begin
        if rst_asic = '1' then
            host_to_mesh <= (others => '0');
            pcie_tx_valid <= '0';
            pcie_tx_data  <= (others => '0');

        elsif rising_edge(clk_asic) then
            pcie_tx_valid <= '0';

            if pcie_rx_valid = '1' then
                -- Build a NoC packet: host writes to core (0,0) by default
                -- [dest_y][dest_x][payload]
                pkt(FLIT_WIDTH-1 downto FLIT_WIDTH-8)   := pcie_rx_data(7 downto 0);   -- dest_y
                pkt(FLIT_WIDTH-9 downto FLIT_WIDTH-16)  := pcie_rx_data(15 downto 8);  -- dest_x
                pkt(FLIT_WIDTH-17 downto 0)             := pcie_rx_data(FLIT_WIDTH-17 downto 0); -- payload

                host_to_mesh <= pkt;

                -- Echo completion back to host
                pcie_tx_valid <= '1';
                pcie_tx_data  <= x"0000_0000_0000_0000_0000_0000_0000_CAFE";
            else
                host_to_mesh <= (others => '0');
            end if;
        end if;
    end process;

end architecture;
