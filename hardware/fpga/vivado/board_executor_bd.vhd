-- VHDL-93 interface adapter: Vivado BD rejects a VHDL-2008 module top.
-- Programmable five-port replay executor, AXI4-Lite protocol 2.
-- Capture timestamps refer to the rising edge carrying the indicated event.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity board_executor_bd is
 generic(FRAMES_PER_PORT:positive:=36; MAX_BYTES:positive:=288;
   RX_BYTE_CAP:positive:=65536; RX_EVENT_CAP:positive:=512; PERIOD_BANKS:positive:=8;
   MAX_PERIOD_TICKS:positive:=10000000; GUARD_TICKS:natural:=12336);
 port(clk,resetn:in std_logic;
   s_axi_awaddr:in std_logic_vector(31 downto 0); s_axi_awvalid:in std_logic; s_axi_awready:out std_logic;
   s_axi_wdata:in std_logic_vector(31 downto 0); s_axi_wstrb:in std_logic_vector(3 downto 0);
   s_axi_wvalid:in std_logic; s_axi_wready:out std_logic;
   s_axi_bresp:out std_logic_vector(1 downto 0); s_axi_bvalid:out std_logic; s_axi_bready:in std_logic;
   s_axi_araddr:in std_logic_vector(31 downto 0); s_axi_arvalid:in std_logic; s_axi_arready:out std_logic;
   s_axi_rdata:out std_logic_vector(31 downto 0); s_axi_rresp:out std_logic_vector(1 downto 0);
   s_axi_rvalid:out std_logic; s_axi_rready:in std_logic);
 attribute X_INTERFACE_INFO:string;
 attribute X_INTERFACE_PARAMETER:string;
 attribute X_INTERFACE_INFO of clk:signal is "xilinx.com:signal:clock:1.0 CLK CLK";
 attribute X_INTERFACE_PARAMETER of clk:signal is "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET resetn, FREQ_HZ 100000000";
 attribute X_INTERFACE_INFO of resetn:signal is "xilinx.com:signal:reset:1.0 RESET RST";
 attribute X_INTERFACE_PARAMETER of resetn:signal is "XIL_INTERFACENAME RESET, POLARITY ACTIVE_LOW";
 attribute X_INTERFACE_PARAMETER of s_axi_awaddr:signal is "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 32, READ_WRITE_MODE READ_WRITE, FREQ_HZ 100000000";
 attribute X_INTERFACE_INFO of s_axi_awaddr:signal is "xilinx.com:interface:aximm:1.0 S_AXI AWADDR";
 attribute X_INTERFACE_INFO of s_axi_awvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI AWVALID";
 attribute X_INTERFACE_INFO of s_axi_awready:signal is "xilinx.com:interface:aximm:1.0 S_AXI AWREADY";
 attribute X_INTERFACE_INFO of s_axi_wdata:signal is "xilinx.com:interface:aximm:1.0 S_AXI WDATA";
 attribute X_INTERFACE_INFO of s_axi_wstrb:signal is "xilinx.com:interface:aximm:1.0 S_AXI WSTRB";
 attribute X_INTERFACE_INFO of s_axi_wvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI WVALID";
 attribute X_INTERFACE_INFO of s_axi_wready:signal is "xilinx.com:interface:aximm:1.0 S_AXI WREADY";
 attribute X_INTERFACE_INFO of s_axi_bresp:signal is "xilinx.com:interface:aximm:1.0 S_AXI BRESP";
 attribute X_INTERFACE_INFO of s_axi_bvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI BVALID";
 attribute X_INTERFACE_INFO of s_axi_bready:signal is "xilinx.com:interface:aximm:1.0 S_AXI BREADY";
 attribute X_INTERFACE_INFO of s_axi_araddr:signal is "xilinx.com:interface:aximm:1.0 S_AXI ARADDR";
 attribute X_INTERFACE_INFO of s_axi_arvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI ARVALID";
 attribute X_INTERFACE_INFO of s_axi_arready:signal is "xilinx.com:interface:aximm:1.0 S_AXI ARREADY";
 attribute X_INTERFACE_INFO of s_axi_rdata:signal is "xilinx.com:interface:aximm:1.0 S_AXI RDATA";
 attribute X_INTERFACE_INFO of s_axi_rresp:signal is "xilinx.com:interface:aximm:1.0 S_AXI RRESP";
 attribute X_INTERFACE_INFO of s_axi_rvalid:signal is "xilinx.com:interface:aximm:1.0 S_AXI RVALID";
 attribute X_INTERFACE_INFO of s_axi_rready:signal is "xilinx.com:interface:aximm:1.0 S_AXI RREADY";
end;

architecture adapter of board_executor_bd is
begin
 executor: entity work.board_executor_axi
 generic map (FRAMES_PER_PORT,MAX_BYTES,RX_BYTE_CAP,RX_EVENT_CAP,PERIOD_BANKS,MAX_PERIOD_TICKS,GUARD_TICKS)
 port map (clk,resetn,s_axi_awaddr,s_axi_awvalid,s_axi_awready,s_axi_wdata,s_axi_wstrb,s_axi_wvalid,s_axi_wready,s_axi_bresp,s_axi_bvalid,s_axi_bready,s_axi_araddr,s_axi_arvalid,s_axi_arready,s_axi_rdata,s_axi_rresp,s_axi_rvalid,s_axi_rready);
end architecture;
