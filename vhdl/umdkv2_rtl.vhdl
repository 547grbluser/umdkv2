--
-- Copyright (C) 2009-2012 Chris McClelland
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Lesser General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Lesser General Public License for more details.
--
-- You should have received a copy of the GNU Lesser General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.mem_ctrl_pkg.all;

entity umdkv2 is
	port(
		clk_in         : in  std_logic;
		reset_in       : in  std_logic;

		-- DVR interface -----------------------------------------------------------------------------
		chanAddr_in    : in  std_logic_vector(6 downto 0);  -- the selected channel (0-127)

		-- Host >> FPGA pipe:
		h2fData_in     : in  std_logic_vector(7 downto 0);  -- data lines used when the host writes to a channel
		h2fValid_in    : in  std_logic;                     -- '1' means "on the next clock rising edge, please accept the data on h2fData"
		h2fReady_out   : out std_logic;                     -- channel logic can drive this low to say "I'm not ready for more data yet"

		-- Host << FPGA pipe:
		f2hData_out    : out std_logic_vector(7 downto 0);  -- data lines used when the host reads from a channel
		f2hValid_out   : out std_logic;                     -- channel logic can drive this low to say "I don't have data ready for you"
		f2hReady_in    : in  std_logic;                     -- '1' means "on the next clock rising edge, put your next byte of data on f2hData"

		-- SDRAM interface ---------------------------------------------------------------------------
		ramCmd_out     : out   std_logic_vector(2 downto 0);
		ramBank_out    : out   std_logic_vector(1 downto 0);
		ramAddr_out    : out   std_logic_vector(11 downto 0);
		ramData_io     : inout std_logic_vector(15 downto 0);
		ramLDQM_out    : out   std_logic;
		ramUDQM_out    : out   std_logic;

		-- MegaDrive interface -----------------------------------------------------------------------
		mdReset_out    : out   std_logic;
		mdDriveBus_out : out   std_logic;
		mdDTACK_out    : out   std_logic;
		mdAddr_in      : in    std_logic_vector(22 downto 0);
		mdData_io      : inout std_logic_vector(15 downto 0);
		mdOE_in        : in    std_logic;
		mdAS_in        : in    std_logic;
		mdLDSW_in      : in    std_logic;
		mdUDSW_in      : in    std_logic
	);
end entity;

architecture structural of umdkv2 is
	-- Command Pipe input
	signal cmdData    : std_logic_vector(7 downto 0);
	signal cmdValid   : std_logic;
	signal cmdReady   : std_logic;

	-- 8-bit Command Pipe (FIFO -> 8to16)
	signal cmd8Data   : std_logic_vector(7 downto 0);
	signal cmd8Valid  : std_logic;
	signal cmd8Ready  : std_logic;
	
	-- 16-bit Command Pipe (8to16 -> MemPipe)
	signal cmd16Data  : std_logic_vector(15 downto 0);
	signal cmd16Valid : std_logic;
	signal cmd16Ready : std_logic;

	-- 16-bit Response Pipe (MemPipe -> 16to8)
	signal rsp16Data  : std_logic_vector(15 downto 0);
	signal rsp16Valid : std_logic;
	signal rsp16Ready : std_logic;

	-- 8-bit Response Pipe (16to8 -> FIFO)
	signal rsp8Data   : std_logic_vector(7 downto 0);
	signal rsp8Valid  : std_logic;
	signal rsp8Ready  : std_logic;

	-- Response Pipe output
	signal rspData    : std_logic_vector(7 downto 0);
	signal rspValid   : std_logic;
	signal rspReady   : std_logic;

	-- Pipe interface
	signal ppReady    : std_logic;
	signal ppCmd      : MCCmdType;
	signal ppAddr     : std_logic_vector(22 downto 0);
	signal ppDataWr   : std_logic_vector(15 downto 0);
	signal ppDataRd   : std_logic_vector(15 downto 0);
	signal ppRDV      : std_logic;
	
	-- Memory controller interface
	signal mcAutoMode : std_logic;
	signal mcReady    : std_logic;
	signal mcCmd      : MCCmdType;
	signal mcAddr     : std_logic_vector(22 downto 0);
	signal mcDataWr   : std_logic_vector(15 downto 0);
	signal mcDataRd   : std_logic_vector(15 downto 0);
	signal mcRDV      : std_logic;

	-- Registers implementing the channels
	signal reg1       : std_logic_vector(1 downto 0) := "01";
	signal reg1_next  : std_logic_vector(1 downto 0);

	-- Trace data
	signal count      : unsigned(31 downto 0) := (others => '0');
	signal count_next : unsigned(31 downto 0);
	signal trc48Data  : std_logic_vector(47 downto 0);
	signal trc48Valid : std_logic;
	signal trc48Ready : std_logic;
	signal trc8Data   : std_logic_vector(7 downto 0);
	signal trc8Valid  : std_logic;
	signal trc8Ready  : std_logic;
	signal trcData    : std_logic_vector(7 downto 0);
	signal trcValid   : std_logic;
	signal trcReady   : std_logic;
	signal trcDepth   : std_logic_vector(14 downto 0);
	
	-- Readable versions of external driven signals
	signal mdReset    : std_logic;
begin
	-- Infer registers
	process(clk_in)
	begin
		if ( rising_edge(clk_in) ) then
			if ( reset_in = '1' ) then
				reg1 <= "01";
				count <= (others => '0');
			else
				reg1 <= reg1_next;
				count <= count_next;
			end if;
		end if;
	end process;

	-- Select values to return for each channel when the host is reading
	with chanAddr_in select f2hData_out <=
		rspData                     when "0000000",
		"000000" & reg1             when "0000001",
		trcData                     when "0000010",
		"0" & trcDepth(14 downto 8) when "0000011",
		trcDepth(7 downto 0)        when "0000100",
		x"00"                       when others;

	-- Generate valid signal for responding to host reads
	with chanAddr_in select f2hValid_out <=
		rspValid when "0000000",
		'1'      when "0000001",
		trcValid when "0000010",
		'1'      when "0000011",
		'1'      when "0000100",
		'0'      when others;

	trcReady <=
		f2hReady_in when chanAddr_in = "0000010"
		else '0';

	count_next <=
		count + 1 when trc48Ready = '1'
		else count;
	--trc48Data <= std_logic_vector(count(31 downto 16)) & std_logic_vector(count);
	--trc48Valid <= not(reset_in);

	-- Trace Pipe 48->8 converter
	trace_conv: entity work.conv_48to8
		port map(
			clk_in      => clk_in,
			reset_in    => reset_in,
			
			data48_in   => trc48Data,
			valid48_in  => trc48Valid,
			ready48_out => trc48Ready,
			
			data8_out   => trc8Data,
			valid8_out  => trc8Valid,
			ready8_in   => trc8Ready
		);

	-- Trace FIFO
	trace_fifo: entity work.trace_fifo_wrapper
		port map(
			clk_in      => clk_in,
			depth_out   => trcDepth,
			
			-- Production end
			inputData_in => trc8Data,
			inputValid_in => trc8Valid,
			inputReady_out => trc8Ready,

			-- Consumption end
			outputData_out => trcData,
			outputValid_out => trcValid,
			outputReady_in => trcReady
		);

	-- Command Pipe FIFO
	cmd_fifo: entity work.fifo
		generic map(
			WIDTH => 8,
			DEPTH => 2
		)
		port map(
			clk_in          => clk_in,
			reset_in        => '0',
			depth_out       => open,

			-- Input pipe
			inputData_in    => cmdData,
			inputValid_in   => cmdValid,
			inputReady_out  => cmdReady,

			-- Output pipe
			outputData_out  => cmd8Data,
			outputValid_out => cmd8Valid,
			outputReady_in  => cmd8Ready
		);

	-- Command Pipe 8->16 converter
	cmd_conv: entity work.conv_8to16
		port map(
			clk_in       => clk_in,
			reset_in     => '0',
			data8_in     => cmd8Data,
			valid8_in    => cmd8Valid,
			ready8_out   => cmd8Ready,
			data16_out   => cmd16Data,
			valid16_out  => cmd16Valid,
			ready16_in   => cmd16Ready
		);

	-- Response Pipe 16->8 converter
	rsp_conv: entity work.conv_16to8
		port map(
			clk_in      => clk_in,
			reset_in    => '0',
			data16_in   => rsp16Data,
			valid16_in  => rsp16Valid,
			ready16_out => rsp16Ready,
			data8_out   => rsp8Data,
			valid8_out  => rsp8Valid,
			ready8_in   => rsp8Ready
		);

	-- Response Pipe FIFO
	rsp_fifo: entity work.fifo
		generic map(
			WIDTH => 8,
			DEPTH => 2
		)
		port map(
			clk_in          => clk_in,
			reset_in        => '0',
			depth_out       => open,

			-- Input pipe
			inputData_in    => rsp8Data,
			inputValid_in   => rsp8Valid,
			inputReady_out  => rsp8Ready,

			-- Output pipe
			outputData_out  => rspData,
			outputValid_out => rspValid,
			outputReady_in  => rspReady
		);

	-- Memory Pipe Unit (connects command & response pipes to the memory controller)
	mem_pipe: entity work.mem_pipe
		port map(
			clk_in       => clk_in,
			reset_in     => reset_in,

			-- Command pipe
			cmdData_in   => cmd16Data,
			cmdValid_in  => cmd16Valid,
			cmdReady_out => cmd16Ready,

			-- Response pipe
			rspData_out  => rsp16Data,
			rspValid_out => rsp16Valid,
			rspReady_in  => rsp16Ready,

			-- Memory controller interface
			mcReady_in   => ppReady,
			mcCmd_out    => ppCmd,
			mcAddr_out   => ppAddr,
			mcData_out   => ppDataWr,
			mcData_in    => ppDataRd,
			mcRDV_in     => ppRDV
		);

	-- Instantiate the memory arbiter unit
	mem_arbiter: entity work.mem_arbiter
		port map(
			clk_in         => clk_in,
			reset_in       => reset_in,

			-- Connetion to mem_pipe
			ppReady_out    => ppReady,
			ppCmd_in       => ppCmd,
			ppAddr_in      => ppAddr,
			ppData_in      => ppDataWr,
			ppData_out     => ppDataRd,
			ppRDV_out      => ppRDV,

			-- Connection to mem_ctrl
			mcAutoMode_out => mcAutoMode,
			mcReady_in     => mcReady,
			mcCmd_out      => mcCmd,
			mcAddr_out     => mcAddr,
			mcData_out     => mcDataWr,
			mcData_in      => mcDataRd,
			mcRDV_in       => mcRDV,

			-- Connection to MegaDrive
			mdDriveBus_out => mdDriveBus_out,
			mdReset_in     => mdReset,
			mdDTACK_out    => mdDTACK_out,
			mdAddr_in      => mdAddr_in,
			mdData_io      => mdData_io,
			mdOE_in        => mdOE_in,
			mdAS_in        => mdAS_in,
			mdLDSW_in      => mdLDSW_in,
			mdUDSW_in      => mdUDSW_in,

			-- Trace pipe
			traceEnable_in => reg1(1),
			traceData_out  => trc48Data,
			traceValid_out => trc48Valid
			--traceData_out  => open, --trc48Data,
			--traceValid_out => open  --trc48Valid
		);
	
	-- Memory controller (connects SDRAM to Memory Pipe Unit)
	mem_ctrl: entity work.mem_ctrl
		generic map(
			INIT_COUNT     => "1" & x"2C0",  --\
			REFRESH_DELAY  => "0" & x"300",  -- Much longer in real hardware!
			REFRESH_LENGTH => "0" & x"002"   --/
		)
		port map(
			clk_in       => clk_in,
			reset_in     => reset_in,

			-- Client interface
			mcAutoMode_in => mcAutoMode,
			mcReady_out   => mcReady,
			mcCmd_in      => mcCmd,
			mcAddr_in     => mcAddr,
			mcData_in     => mcDataWr,
			mcData_out    => mcDataRd,
			mcRDV_out     => mcRDV,

			-- SDRAM interface
			ramCmd_out    => ramCmd_out,
			ramBank_out   => ramBank_out,
			ramAddr_out   => ramAddr_out,
			ramData_io    => ramData_io,
			ramLDQM_out   => ramLDQM_out,
			ramUDQM_out   => ramUDQM_out
		);

	reg1_next <=
		h2fData_in(1 downto 0) when chanAddr_in = "0000001" and h2fValid_in = '1'
		else reg1;

	-- Connect channel 0 writes to the SDRAM command pipe and response pipe ready to ch0 read ready
	cmdData <=
		h2fData_in when chanAddr_in = "0000000" and h2fValid_in = '1'
		else (others => 'X');
	cmdValid <=
		h2fValid_in when chanAddr_in = "0000000"
		else '0';
	rspReady <=
		f2hReady_in when chanAddr_in = "0000000"
		else '0';

	-- Generate ready signal for throttling host writes
	with chanAddr_in select h2fReady_out <=
		cmdReady when "0000000",
		'1'      when "0000001",
		'0'      when others;

	-- Drive MegaDrive RESET line
	mdReset     <= reg1(0);  -- MD in reset when R1(0) high
	mdReset_out <= mdReset;
end architecture;
