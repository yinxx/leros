--
--  Copyright 2011 Martin Schoeberl <masca@imm.dtu.dk>,
--                 Technical University of Denmark, DTU Informatics. 
--  All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
-- 
--    1. Redistributions of source code must retain the above copyright notice,
--       this list of conditions and the following disclaimer.
-- 
--    2. Redistributions in binary form must reproduce the above copyright
--       notice, this list of conditions and the following disclaimer in the
--       documentation and/or other materials provided with the distribution.
-- 
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER ``AS IS'' AND ANY EXPRESS
-- OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
-- OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
-- NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY
-- DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-- ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
-- THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-- 
-- The views and conclusions contained in the software and documentation are
-- those of the authors and should not be interpreted as representing official
-- policies, either expressed or implied, of the copyright holder.
-- 

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.leros_types.all;

-- fetch and decode stage

entity leros_fedec is
	port  (
		clk : in std_logic;
		reset : in std_logic;
		din : in fedec_in_type;
		dout : out fedec_out_type;
		icache_in : in im_cache_in_type;
		icache_out : out im_cache_out_type
	);
end leros_fedec;

architecture rtl of leros_fedec is

	signal imin : im_in_type;
	signal imout : im_out_type;
	
	signal zf, do_branch, all_valid : std_logic;
	
	signal pc, pc_next, pc_op, pc_add : unsigned(IM_BITS-1 downto 0);
	signal decode : decode_type;
	
	signal addr_save : std_logic_vector(31 downto 0);
	signal addr_mux : std_logic_vector(31 downto 0);

	signal load_addr_q : std_logic;
begin

	dout.pc <= std_logic_vector(pc_add);
	
	imin.rdaddr <= std_logic_vector(pc_next);
	imin.pc <= std_logic_vector(pc);
	
	im: entity work.leros_im port map(
		clk, reset, imin, imout, icache_in, icache_out
	);

	dec: entity work.leros_decode port map(
		imout.data(15 downto 8), decode
	);
	
process(clk)
begin
	if clk = '1' and clk'Event then
		if all_valid = '1' then
			load_addr_q <= decode.load_addr after 100 ps;
			if load_addr_q = '1' then
				addr_save <= din.dm_data after 100 ps;
			end if;
		end if;
	end if;
end process;

addr_mux <= din.dm_data when load_addr_q = '1' else
					addr_save after 100 ps;
	
-- DM address selection
process(decode, din, imout, addr_mux)
	variable addr : std_logic_vector(31 downto 0);
begin
	addr := std_logic_vector(unsigned(addr_mux) + unsigned(imout.data(7 downto 0)));
	-- MUX for indirect load/store (from unregistered decode)
	if decode.indls='1' then
		dout.dm_addr <= addr(DM_BITS-1 downto 0) after 100 ps;
	else
		-- If DM > 256 zero extend the varidx
		dout.dm_addr <= std_logic_vector(resize(unsigned(imout.data(7 downto 0)), DM_BITS)) after 100 ps;
	end if;

end process;

-- branch 
process(decode, din, do_branch, imout, pc, pc_add, pc_op, zf)
begin
	-- should be checked in ModelSim
  	if unsigned(din.accu)=0 then
		zf <= '1' after 100 ps;
	else
		zf <= '0' after 100 ps;
	end if;
	do_branch <= '0' after 100 ps; -- is setting and reading a signal in on process ok style?
	
	-- check branch condition
	if decode.br_op='1' then
		case imout.data(10 downto 8) is
			when "000" =>		-- branch
				do_branch <= '1' after 100 ps;
			when "001" =>		-- brz
				if zf='1' then
					do_branch <= '1' after 100 ps;
				end if;
			when "010" =>		-- brnz
				if zf='0' then
					do_branch <= '1' after 100 ps;
				end if;
			when "011" =>		-- brp
				if din.accu(31)='0' then
					do_branch <= '1' after 100 ps;
				end if;
			when "100" =>		-- brn
				if din.accu(31)='1' then
					do_branch <= '1' after 100 ps;
				end if;
			when others =>
				null;
		end case;
	end if;
	
	-- shall we do the branch in the ex stage so
	-- we will have a real branch delay slot?
	-- branch
	if do_branch='1' then
		pc_op <= unsigned(resize(signed(imout.data(7 downto 0)), IM_BITS)) after 100 ps;
	else
		pc_op <= to_unsigned(1, IM_BITS) after 100 ps;
	end if;
	pc_add <= pc + pc_op after 100 ps;
	-- jump and link
	if decode.jal='1' then
		pc_next <= unsigned(din.accu(IM_BITS-1 downto 0)) after 100 ps;
	else
		pc_next <= pc_add after 100 ps;
	end if;
	
end process;

dout.valid <= all_valid;
imin.valid <= all_valid;
all_valid <= '1' when imout.valid = '1' and din.dmiss = '0' else '0';
dout.decode <= decode;
	
-- pc register
process(clk, reset)
begin
	if reset='1' then
		pc <= (others => '0') after 100 ps;
	elsif rising_edge(clk) then
		if all_valid = '1' then --Stall pc
			pc <= pc_next after 100 ps;
			dout.dec <= decode after 100 ps;
	--		if decode.add_sub='1' then
			-- sign extension depends on loadh?????
			if decode.loadh='1' then
				dout.imm(7 downto 0) <= (others => '0') after 100 ps;
				dout.imm(15 downto 8) <= imout.data(7 downto 0) after 100 ps;
				dout.imm(31 downto 16) <= (others => '0') after 100 ps;
			elsif	decode.loadhl='1' then
				dout.imm(15 downto 0) <= (others => '0') after 100 ps;
				dout.imm(23 downto 16) <= imout.data(7 downto 0) after 100 ps;
				dout.imm(31 downto 24) <= (others => '0') after 100 ps;
			elsif decode.loadhh='1' then
				dout.imm(23 downto 0) <= (others => '0') after 100 ps;
				dout.imm(31 downto 24) <= imout.data(7 downto 0) after 100 ps;
			else 
				dout.imm <= std_logic_vector(resize(signed(imout.data(7 downto 0)), 32)) after 100 ps;
			end if;
		end if;
--		else
--			immr(7 downto 0) <= imout.data(7 downto 0);
--			immr(15 downto 0) <= (others => '0');
--		end if;
	end if;
end process;

end rtl;