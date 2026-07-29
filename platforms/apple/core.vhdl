library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Reusable compute tile. CORE_TYPE selects the behavior:
--   "CPU"  -> out-of-order-like scalar core with L1 cache
--   "GPU"  -> single-instruction-multiple-thread shader core with shared memory
--   "NNE"  -> Neural Engine matrix multiply accumulator
entity compute_core is
    generic (
        CORE_ID        : integer := 0;
        CORE_TYPE      : string(1 to 3) := "CPU";
        NUM_LANES      : integer := 4;      -- 1 for CPU, many for GPU, matrix width for NNE
        REG_FILE_DEPTH : integer := 32;     -- registers per lane
        L1_DEPTH       : integer := 512;    -- L1 / shared memory / accumulator depth
        DATA_WIDTH     : integer := 32
    );
    port (
        clk : in std_logic;
        rst : in std_logic;

        -- Instruction stream from host/command unit
        inst_in       : in  std_logic_vector(31 downto 0);
        inst_valid    : in  std_logic;
        inst_ready    : out std_logic;

        -- Unified coherent fabric interface
        fabric_req_addr  : out std_logic_vector(31 downto 0);
        fabric_req_wdata : out std_logic_vector(DATA_WIDTH-1 downto 0);
        fabric_req_we    : out std_logic;
        fabric_req_valid : out std_logic;
        fabric_req_ready : in  std_logic;

        fabric_resp_rdata : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        fabric_resp_valid : in  std_logic;

        -- CPU-only interrupt line
        interrupt_in  : in  std_logic
    );
end entity;

architecture conceptual of compute_core is

    -- L1 / shared memory / accumulator storage
    type l1_t is array (0 to L1_DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal l1_mem : l1_t;

    -- Register file: NUM_LANES * REG_FILE_DEPTH entries
    type reg_file_t is array (0 to NUM_LANES*REG_FILE_DEPTH-1)
                       of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal reg_file : reg_file_t;

    -- Program counter and decode state
    signal pc : unsigned(15 downto 0);
    signal instr : std_logic_vector(31 downto 0);

    -- Instruction fields
    alias op  : std_logic_vector(3 downto 0) is instr(31 downto 28);
    alias rd  : std_logic_vector(4 downto 0) is instr(27 downto 23);
    alias rs1 : std_logic_vector(4 downto 0) is instr(22 downto 18);
    alias imm : std_logic_vector(15 downto 0) is instr(15 downto 0);

    -- State machine
    type state_t is (FETCH, DECODE, EXEC, WAIT_FABRIC, WAIT_RESP);
    signal state : state_t;

    -- GPU SIMT state
    signal warp_active : std_logic;
    signal lane_id     : integer range 0 to NUM_LANES-1;

    -- NNE accumulator
    signal acc_row     : integer range 0 to NUM_LANES-1;
    signal acc_col     : integer range 0 to NUM_LANES-1;

begin

    inst_ready <= '1' when state = FETCH else '0';

    main_fsm : process(clk, rst)
        variable ridx, ridx_b : integer;
        variable addr : integer;
        variable result : std_logic_vector(DATA_WIDTH-1 downto 0);
    begin
        if rst = '1' then
            pc <= (others => '0');
            state <= FETCH;
            fabric_req_valid <= '0';
            warp_active <= '0';
            lane_id <= 0;
            acc_row <= 0;
            acc_col <= 0;

        elsif rising_edge(clk) then
            fabric_req_valid <= '0';

            case state is
                when FETCH =>
                    if inst_valid = '1' then
                        instr <= inst_in;
                        state <= DECODE;
                    end if;

                when DECODE =>
                    state <= EXEC;

                when EXEC =>
                    if CORE_TYPE = "CPU" then
                        -- CPU: scalar out-of-order-like execution (simplified to in-order here)
                        case op is
                            when x"1" => -- ALU add
                                ridx := to_integer(unsigned(rs1)) mod REG_FILE_DEPTH;
                                reg_file(ridx) <= std_logic_vector(
                                    unsigned(reg_file(ridx)) + unsigned(imm));
                                pc <= pc + 1;
                                state <= FETCH;

                            when x"2" => -- LOAD from coherent fabric
                                fabric_req_addr <= std_logic_vector(resize(unsigned(imm) & x"0000", 32));
                                fabric_req_we <= '0';
                                fabric_req_valid <= '1';
                                state <= WAIT_FABRIC;

                            when x"3" => -- STORE to coherent fabric
                                ridx := to_integer(unsigned(rs1)) mod REG_FILE_DEPTH;
                                fabric_req_addr <= std_logic_vector(resize(unsigned(imm) & x"0000", 32));
                                fabric_req_wdata <= reg_file(ridx);
                                fabric_req_we <= '1';
                                fabric_req_valid <= '1';
                                state <= WAIT_FABRIC;

                            when x"4" => -- branch
                                if reg_file(to_integer(unsigned(rs1)) mod REG_FILE_DEPTH) /= x"00000000" then
                                    pc <= unsigned(imm);
                                else
                                    pc <= pc + 1;
                                end if;
                                state <= FETCH;

                            when x"F" => -- halt / interrupt return
                                state <= FETCH;

                            when others =>
                                pc <= pc + 1;
                                state <= FETCH;
                        end case;

                    elsif CORE_TYPE = "GPU" then
                        -- GPU: SIMT execution across lanes
                        case op is
                            when x"1" => -- vector add
                                for t in 0 to NUM_LANES-1 loop
                                    ridx := t*REG_FILE_DEPTH + (to_integer(unsigned(rd)) mod REG_FILE_DEPTH);
                                    ridx_b := t*REG_FILE_DEPTH + (to_integer(unsigned(rs1)) mod REG_FILE_DEPTH);
                                    reg_file(ridx) <= std_logic_vector(
                                        unsigned(reg_file(ridx_b)) + unsigned(imm));
                                end loop;
                                pc <= pc + 1;
                                state <= FETCH;

                            when x"2" => -- load into shared L1 memory per lane
                                addr := to_integer(unsigned(imm)) mod L1_DEPTH;
                                for t in 0 to NUM_LANES-1 loop
                                    l1_mem((addr + t) mod L1_DEPTH) <= reg_file(t*REG_FILE_DEPTH + 0);
                                end loop;
                                pc <= pc + 1;
                                state <= FETCH;

                            when x"3" => -- global load through fabric
                                fabric_req_addr <= std_logic_vector(resize(unsigned(imm) & x"0000", 32));
                                fabric_req_we <= '0';
                                fabric_req_valid <= '1';
                                state <= WAIT_FABRIC;

                            when x"4" => -- global store through fabric
                                fabric_req_addr <= std_logic_vector(resize(unsigned(imm) & x"0000", 32));
                                fabric_req_wdata <= reg_file(0); -- lane 0 scalar
                                fabric_req_we <= '1';
                                fabric_req_valid <= '1';
                                state <= WAIT_FABRIC;

                            when x"F" =>
                                warp_active <= '0';
                                state <= FETCH;

                            when others =>
                                pc <= pc + 1;
                                state <= FETCH;
                        end case;

                    else
                        -- NNE: fixed-function matrix multiply-accumulate
                        case op is
                            when x"1" => -- MAC step: A[acc_row] * B[acc_col] -> acc[acc_row][acc_col]
                                result := std_logic_vector(
                                    resize(unsigned(l1_mem(acc_row)) * unsigned(l1_mem(L1_DEPTH-1-acc_col)), DATA_WIDTH));
                                l1_mem(acc_row*NUM_LANES + acc_col) <= std_logic_vector(
                                    unsigned(l1_mem(acc_row*NUM_LANES + acc_col)) + unsigned(result));
                                if acc_col = NUM_LANES-1 then
                                    acc_col <= 0;
                                    if acc_row = NUM_LANES-1 then
                                        acc_row <= 0;
                                        pc <= pc + 1;
                                        state <= FETCH;
                                    else
                                        acc_row <= acc_row + 1;
                                    end if;
                                else
                                    acc_col <= acc_col + 1;
                                end if;

                            when x"2" => -- write result back to fabric
                                fabric_req_addr <= std_logic_vector(resize(unsigned(imm) & x"0000", 32) + to_unsigned(acc_row*NUM_LANES + acc_col, 32));
                                fabric_req_wdata <= l1_mem(acc_row*NUM_LANES + acc_col);
                                fabric_req_we <= '1';
                                fabric_req_valid <= '1';
                                state <= WAIT_FABRIC;

                            when others =>
                                pc <= pc + 1;
                                state <= FETCH;
                        end case;
                    end if;

                when WAIT_FABRIC =>
                    if fabric_req_ready = '1' then
                        if fabric_req_we = '1' then
                            -- writes return immediately in this simple model
                            state <= FETCH;
                            pc <= pc + 1;
                        else
                            state <= WAIT_RESP;
                        end if;
                    end if;

                when WAIT_RESP =>
                    if fabric_resp_valid = '1' then
                        reg_file(0) <= fabric_resp_rdata;
                        state <= FETCH;
                        pc <= pc + 1;
                    end if;

                when others =>
                    state <= FETCH;
            end case;
        end if;
    end process;

end architecture;
