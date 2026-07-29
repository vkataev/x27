library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Conceptual Tensix core: a tile in a 2D mesh.
-- Each tile owns local SRAM, a tiny scalar controller, and a SIMD engine.
-- Data moves between tiles via explicit NoC packets, not via caches.
entity tensix_core is
    generic (
        -- Position of this core in the 2D mesh
        CORE_X : integer := 0;
        CORE_Y : integer := 0;

        -- Local scratchpad size and width
        SRAM_DEPTH  : integer := 4096;          -- e.g. 16 KB if DATA_WIDTH=32
        DATA_WIDTH  : integer := 32;              -- scalar word width
        SIMD_LANES  : integer := 16;              -- SIMD/vector lanes

        -- NoC flit width: dest coordinates + payload
        FLIT_WIDTH  : integer := 32 + 8 + 8;      -- payload + dest_x + dest_y
        ADDR_WIDTH  : integer := 16               -- instruction/operand addresses
    );
    port (
        clk : in std_logic;
        rst : in std_logic;

        -- NoC interfaces to neighbors: (N, S, E, W)
        -- Each flit carries a payload plus destination (x,y)
        noc_in_n  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);
        noc_in_s  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);
        noc_in_e  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);
        noc_in_w  : in  std_logic_vector(FLIT_WIDTH-1 downto 0);

        noc_out_n : out std_logic_vector(FLIT_WIDTH-1 downto 0);
        noc_out_s : out std_logic_vector(FLIT_WIDTH-1 downto 0);
        noc_out_e : out std_logic_vector(FLIT_WIDTH-1 downto 0);
        noc_out_w : out std_logic_vector(FLIT_WIDTH-1 downto 0);

        -- Simple memory/DMA interface to off-chip DRAM controller
        -- The real chip uses multiple memory controllers on the NoC.
        dram_req_addr  : out std_logic_vector(ADDR_WIDTH-1 downto 0);
        dram_req_wdata : out std_logic_vector(DATA_WIDTH-1 downto 0);
        dram_req_we    : out std_logic;
        dram_req_valid : out std_logic;
        dram_resp_rdata : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        dram_resp_valid : in  std_logic
    );
end entity;

architecture conceptual of tensix_core is

    -----------------------------------------------------------------------
    -- 1. Local SRAM (distributed scratchpad)
    -----------------------------------------------------------------------
    type sram_t is array (0 to SRAM_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal sram : sram_t;

    -----------------------------------------------------------------------
    -- 2. Scalar controller state (minimal RISC-V-ish subset)
    -----------------------------------------------------------------------
    signal pc   : unsigned(ADDR_WIDTH-1 downto 0);     -- program counter
    signal regs : std_logic_vector(DATA_WIDTH-1 downto 0); -- one scalar accumulator (simplified)
    signal instr : std_logic_vector(31 downto 0);       -- fetched instruction

    type state_t is (FETCH, DECODE, EXEC, WAIT_SRAM, WAIT_NOC, WAIT_DRAM);
    signal state : state_t;

    -- Instruction field decode (conceptual encoding)
    alias op   : std_logic_vector(3 downto 0) is instr(31 downto 28);
    alias sra  : std_logic_vector(ADDR_WIDTH-1 downto 0) is instr(27 downto 12);
    alias srb  : std_logic_vector(ADDR_WIDTH-1 downto 0) is instr(11 downto 0);

    -----------------------------------------------------------------------
    -- 3. SIMD/Tensor engine state
    -----------------------------------------------------------------------
    type vec_t is array (0 to SIMD_LANES-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal vec_a, vec_b, vec_c : vec_t;

    -- Simple vector FSM
    signal vec_busy : std_logic;

    -----------------------------------------------------------------------
    -- 4. NoC packet format helpers
    -----------------------------------------------------------------------
    -- Flit layout: [DATA_WIDTH-1:0] payload, [DATA_WIDTH+7:DATA_WIDTH] dest_y, [DATA_WIDTH+15:DATA_WIDTH+8] dest_x
    constant PAYLOAD_LO : integer := 0;
    constant PAYLOAD_HI : integer := DATA_WIDTH-1;
    constant DEST_X_LO  : integer := DATA_WIDTH;
    constant DEST_X_HI  : integer := DATA_WIDTH+7;
    constant DEST_Y_LO  : integer := DATA_WIDTH+8;
    constant DEST_Y_HI  : integer := DATA_WIDTH+15;

    -- Minimal outgoing NoC buffer
    signal out_flit  : std_logic_vector(FLIT_WIDTH-1 downto 0);
    signal out_valid : std_logic;
    signal out_dir   : integer range 0 to 3; -- 0=N,1=S,2=E,3=W

begin

    -----------------------------------------------------------------------
    -- NoC: route incoming flits.
    -- If flit is addressed to THIS core, capture it into local SRAM.
    -- Otherwise forward it toward destination.
    -- Real routers are much more sophisticated (virtual channels, arbitration).
    -----------------------------------------------------------------------
    noc_routing : process(clk, rst)
        variable dst_x, dst_y : unsigned(7 downto 0);
        variable payload      : std_logic_vector(DATA_WIDTH-1 downto 0);
    begin
        if rst = '1' then
            noc_out_n <= (others => '0');
            noc_out_s <= (others => '0');
            noc_out_e <= (others => '0');
            noc_out_w <= (others => '0');
        elsif rising_edge(clk) then
            -- Default: clear outputs
            noc_out_n <= (others => '0');
            noc_out_s <= (others => '0');
            noc_out_e <= (others => '0');
            noc_out_w <= (others => '0');

            -- Check one incoming flit per cycle as a simplification.
            -- Real routers arbitrate multiple inputs each cycle.
            if noc_in_e(DEST_X_HI) /= (7 downto 0 => '0') or noc_in_e(DEST_Y_HI) /= (7 downto 0 => '0') then
                dst_x := unsigned(noc_in_e(DEST_X_HI downto DEST_X_LO));
                dst_y := unsigned(noc_in_e(DEST_Y_HI downto DEST_Y_LO));
                payload := noc_in_e(PAYLOAD_HI downto PAYLOAD_LO);

                if to_integer(dst_x) = CORE_X and to_integer(dst_y) = CORE_Y then
                    -- Flit is for us: in real HW this would write to a NoC-to-SRAM path.
                    sram(0) <= payload; -- simplified capture
                elsif to_integer(dst_x) > CORE_X then
                    noc_out_w <= noc_in_e; -- forward west? depends on coordinate system
                elsif to_integer(dst_x) < CORE_X then
                    noc_out_e <= noc_in_e;
                elsif to_integer(dst_y) > CORE_Y then
                    noc_out_s <= noc_in_e;
                else
                    noc_out_n <= noc_in_e;
                end if;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------
    -- Main scalar control FSM
    -----------------------------------------------------------------------
    control_fsm : process(clk, rst)
        variable sra_int : integer range 0 to SRAM_DEPTH-1;
    begin
        if rst = '1' then
            pc    <= (others => '0');
            state <= FETCH;
            vec_busy <= '0';
            dram_req_valid <= '0';
            dram_req_we    <= '0';

        elsif rising_edge(clk) then
            sra_int := to_integer(unsigned(sra(15 downto 0))) mod SRAM_DEPTH;
            dram_req_valid <= '0'; -- pulse valid each cycle as needed

            case state is
                when FETCH =>
                    -- In real design this reads from an instruction SRAM.
                    -- Here we just load a dummy opcode for illustration.
                    instr <= x"1000_0001"; -- example: NOP-like
                    state <= DECODE;

                when DECODE =>
                    state <= EXEC;

                when EXEC =>
                    case op is
                        -- LOAD: scalar load from local SRAM into accumulator
                        when x"0" =>
                            regs <= sram(sra_int);
                            state <= FETCH;
                            pc <= pc + 1;

                        -- STORE: scalar store from accumulator to local SRAM
                        when x"1" =>
                            sram(sra_int) <= regs;
                            state <= FETCH;
                            pc <= pc + 1;

                        -- VLOAD: load SIMD lanes from consecutive SRAM addresses
                        when x"2" =>
                            for i in 0 to SIMD_LANES-1 loop
                                vec_a(i) <= sram((sra_int + i) mod SRAM_DEPTH);
                            end loop;
                            state <= FETCH;
                            pc <= pc + 1;

                        -- VADD: vector add across lanes (tensor engine)
                        when x"3" =>
                            for i in 0 to SIMD_LANES-1 loop
                                vec_c(i) <= std_logic_vector(
                                    unsigned(vec_a(i)) + unsigned(vec_b(i)));
                            end loop;
                            state <= FETCH;
                            pc <= pc + 1;

                        -- VMUL: vector multiply across lanes
                        when x"4" =>
                            for i in 0 to SIMD_LANES-1 loop
                                vec_c(i) <= std_logic_vector(
                                    resize(unsigned(vec_a(i)) * unsigned(vec_b(i)), DATA_WIDTH));
                            end loop;
                            state <= FETCH;
                            pc <= pc + 1;

                        -- SEND: push one word to neighbor via NoC
                        when x"5" =>
                            out_flit(PAYLOAD_HI downto PAYLOAD_LO) <= sram(sra_int);
                            out_flit(DEST_X_HI downto DEST_X_LO) <= srb(7 downto 0);
                            out_flit(DEST_Y_HI downto DEST_Y_LO) <= srb(15 downto 8);
                            out_valid <= '1';
                            out_dir <= to_integer(unsigned(srb(17 downto 16)));
                            state <= WAIT_NOC;

                        -- RECV: wait for a flit addressed to this core
                        when x"6" =>
                            state <= WAIT_NOC;

                        -- DRAM_LOAD: explicit read from off-chip memory
                        when x"7" =>
                            dram_req_addr <= sra;
                            dram_req_we <= '0';
                            dram_req_valid <= '1';
                            state <= WAIT_DRAM;

                        when others =>
                            state <= FETCH;
                            pc <= pc + 1;
                    end case;

                when WAIT_NOC =>
                    -- Simplified: assume one cycle to hand off to NoC router
                    out_valid <= '0';
                    state <= FETCH;
                    pc <= pc + 1;

                when WAIT_DRAM =>
                    if dram_resp_valid = '1' then
                        regs <= dram_resp_rdata;
                        state <= FETCH;
                        pc <= pc + 1;
                    end if;

                when others =>
                    state <= FETCH;
            end case;
        end if;
    end process;

    -- Outgoing NoC demux (simplified)
    noc_out_n <= out_flit when out_valid = '1' and out_dir = 0 else (others => '0');
    noc_out_s <= out_flit when out_valid = '1' and out_dir = 1 else (others => '0');
    noc_out_e <= out_flit when out_valid = '1' and out_dir = 2 else (others => '0');
    noc_out_w <= out_flit when out_valid = '1' and out_dir = 3 else (others => '0');

end architecture;
