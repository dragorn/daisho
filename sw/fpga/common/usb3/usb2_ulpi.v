
//
// usb 2.0 ulpi
//
// Copyright (c) 2012-2013 Marshall H.
// All rights reserved.
// This code is released under the terms of the simplified BSD license. 
// See LICENSE.TXT for details.
//

module usb2_ulpi (

// top-level interface
input	wire			reset_n,
input	wire			opt_enable_hs,
output	wire			stat_connected,
output	reg				stat_fs,
output	reg				stat_hs,

// ulpi usb phy connection
input	wire			phy_clk,
inout	wire	[7:0]	phy_d,
input	wire			phy_dir,
output	reg				phy_stp,
input	wire			phy_nxt,

// connection to packet layer
output	wire			pkt_out_act,
output	wire	[7:0]	pkt_out_byte,
output	wire			pkt_out_latch,

output	wire			pkt_in_cts,
output	reg				pkt_in_nxt,
input	wire	[7:0]	pkt_in_byte,
input	wire			pkt_in_latch,

// debug signals
input	wire			dbg_trig,
output	wire	[1:0]	dbg_linestate

);

	
////////////////////////////////////////////////////////////////////
//
// 60mhz ulpi clock domain
//
////////////////////////////////////////////////////////////////////

	reg				reset_1, reset_2;				// synchronizers
	reg				opt_enable_hs_1, opt_enable_hs_2;
	reg				phy_dir_1;
	reg		[7:0]	phy_d_1;
	reg		[7:0]	phy_d_out;
	reg		[7:0]	phy_d_next;
	assign 			phy_d 		= phy_dir_1 ? 8'bZZZZZZZZ : phy_d_out;

	reg		[7:0]	in_rx_cmd;
	reg				know_recv_packet;				// phy will drive NXT and DIR high
													// simaltaneously to signify a receive
													// packet as opposed to normal RX_CMD
													// in any case the RX_CMD will reflect this 
													// just a bit later anyway
	wire	[1:0]	line_state	= in_rx_cmd[1:0];
	wire	[1:0]	vbus_state	= in_rx_cmd[3:2];
	wire	[1:0]	rx_event	= in_rx_cmd[5:4];
	wire			id_gnd		= in_rx_cmd[6];
	wire			alt_int		= in_rx_cmd[7];
	
	wire			sess_end	= (vbus_state == 2'b00);
	wire			sess_valid	= (vbus_state == 2'b10);
	wire			vbus_valid	= (vbus_state == 2'b11);
	assign			stat_connected = vbus_valid;	// in HS mode explicit bit-stuff error will
													// also signal EOP but this is Good Enough(tm)	
	wire			rx_active	= (rx_event[0]);
	wire			rx_error	= (rx_event == 2'b11);
	wire			host_discon	= (rx_event == 2'b10); // only valid in host mode	
	
	reg		[2:0]	tx_cmd_code;					// ULPI TX_CMD code with extra bit
	reg		[7:0]	tx_reg_addr;					// register address (6 and 8bit)
	reg		[7:0]	tx_reg_data_rd;					// data read
	reg		[7:0]	tx_reg_data_wr;					// data to write
	reg		[3:0]	tx_pid;							// packet ID for sending data
	parameter [2:0]	TX_CMD_XMIT_NOPID	= 3'b001,	// two LSB are ULPI cmdcode
					TX_CMD_XMIT_PID		= 3'b101,	
					TX_CMD_REGWR_IMM	= 3'b010,
					TX_CMD_REGWR_EXT	= 3'b110,
					TX_CMD_REGRD_IMM	= 3'b011,
					TX_CMD_REGRD_EXT	= 3'b111;
	
	assign	pkt_out_latch 	= rx_active & phy_dir & phy_nxt;
	assign	pkt_out_byte 	= pkt_out_latch ? phy_d : 8'h0;
	assign	pkt_out_act 	= rx_active;
	
	assign	pkt_in_cts		= (line_state == 2'b01) & ~phy_dir & 
								can_send & (can_send_delay == 4'hF);
	reg				can_send;
	reg		[3:0]	can_send_delay;
	
	reg		[6:0]	state /* synthesis preserve */;
	reg		[6:0]	state_next /* synthesis preserve */;
	parameter [6:0]	ST_RST_0			= 7'd0,
					ST_RST_1			= 7'd1,
					ST_RST_2			= 7'd2,
					ST_RST_3			= 7'd3,
					ST_RST_4			= 7'd4,
					ST_IDLE				= 7'd10,
					ST_RX_0				= 7'd20,
					ST_TXCMD_0			= 7'd30,
					ST_TXCMD_1			= 7'd31,
					ST_TXCMD_2			= 7'd32,
					ST_TXCMD_3			= 7'd33,
					ST_PKT_0			= 7'd40,
					ST_PKT_1			= 7'd41;
	
	reg		[7:0]	dc;
	
	assign 			dbg_linestate = line_state;
	reg 			dbg_trig_1, dbg_trig_2;
	
always @(posedge phy_clk) begin

	{reset_2, reset_1} <= {reset_1, reset_n};
	{opt_enable_hs_2, opt_enable_hs_1} <= {opt_enable_hs_1, opt_enable_hs};
	{dbg_trig_2, dbg_trig_1} <= {dbg_trig_1, dbg_trig};
	phy_dir_1 <= phy_dir;
	phy_d_1 <= phy_d;
	
	dc <= dc + 1'b1;
	
	// clear to send (for packet layer) generation
	if(can_send && line_state == 2'b01) begin
		if(can_send_delay < 4'hF) 
			can_send_delay <= can_send_delay + 1'b1;
	end else begin
		can_send_delay <= 0;
	end
	
	// default state
	phy_stp <= 1'b0;
	// account for the turnaround cycle delay
	phy_d_out <= phy_d_next;
	
	
	// main fsm
	case(state)
	ST_RST_0: begin
		// reset state
		phy_d_out <= 8'h0;
		phy_d_next <= 8'h0;
		phy_stp <= 1'b1;
		phy_dir_1 <= 1'b1;
		pkt_in_nxt <= 1'b0;
		stat_fs <= 1'b0;
		stat_hs <= 1'b0;
		can_send <= 1'b0;
		
		dc <= 0;
		
		state <= ST_RST_1;
	end
	ST_RST_1: begin
		// reset phy and set mode
		tx_cmd_code <= 		TX_CMD_REGWR_IMM;
		tx_reg_addr <= 		6'h4;
		/*
		tx_reg_data_wr <= {	2'b01, 		// Resvd, SuspendM [disabled]
							1'b1, 		// Reset (auto-cleared by PHY)
							2'b00, 		// OpMode [normal]
							1'b1,		// TermSelect [enable]
							2'b00		// XcvrSel [high speed]
		};
		*/
		tx_reg_data_wr <= {	2'b01, 		// Resvd, SuspendM [disabled]
							1'b1, 		// Reset (auto-cleared by PHY)
							2'b00, 		// OpMode [normal]
							1'b1,		// TermSelect [enable]
							2'b01		// XcvrSel [full speed]
		};
		if(dc == 15) begin
			state <= ST_TXCMD_0;	
			state_next <= ST_RST_2;
		end
	end
	ST_RST_2: begin
		// wait for phy to begin reset
		// if times out, try again
		if(dc == 255) state <= ST_RST_0;
		if(phy_dir) state <= ST_RST_3;
	end
	ST_RST_3: begin
		// wait for next rising edge
		// then receive initial RX_CMD
		if(phy_dir & ~phy_dir_1) state <= 20;
		state_next <= ST_RST_4;
	end
	ST_RST_4: begin
		// turn off OTG pulldowns and disable pullup
		// on ID pin (OTG would drive low if connected)
		tx_cmd_code <= 		TX_CMD_REGWR_IMM;
		tx_reg_addr <= 		6'hA;
		tx_reg_data_wr <= 	8'h0;
		
		state <= ST_TXCMD_0;
		state_next <= ST_IDLE;
	end
	
	
	// idle dispatch
	ST_IDLE: begin
		// see if PHY has stuff for us
		if(phy_dir & ~phy_dir_1) begin
			// rising edge of dir
			can_send <= 0;
			know_recv_packet <= phy_nxt;
			
			state <= ST_RX_0;
			state_next <= ST_IDLE;
		end else begin
			// do other stuff
			can_send <= 1;
			
			// accept packet data
			if(pkt_in_latch) state <= ST_PKT_0;
			
			if(~dbg_trig_2 & dbg_trig_1) begin
				tx_cmd_code <= TX_CMD_REGRD_IMM;
				tx_reg_addr <= 0;
				state <= ST_TXCMD_0;
				state_next <= ST_IDLE;
			end
		end
	end
	
	// process RX CMD or start packet
	ST_RX_0: begin
		// data is passed up to the packet layer
		// see combinational logic near the top
		if(~phy_nxt) in_rx_cmd <= phy_d;
		// wait for end of transmission
		if(~phy_dir) state <= state_next;
	end
	
	// send TX CMD
	ST_TXCMD_0: begin
		// drive command onto bus
		if(~tx_cmd_code[2]) begin
			if(~tx_cmd_code[1]) 
				phy_d_out <= {tx_cmd_code[1:0], 6'b0};				// transmit no PID
			else 				
				phy_d_out <= {tx_cmd_code[1:0], tx_reg_addr[5:0]};	// immediate reg r/w
		end else begin
			if(~tx_cmd_code[1]) 
				phy_d_out <= {tx_cmd_code[1:0], 2'b0, tx_pid[3:0]};	// transmit with PID
			else 				
				phy_d_out <= {tx_cmd_code[1:0], 6'b101111};			// extended reg r/w
		end
		
		if(phy_nxt) begin
			// phy has acknowledged the command
			
			if(tx_cmd_code[0]) begin
				// read reg
				// immediate only for now
				// need to insert additional branches for extended addr
				phy_d_out <= 0;
				state <= ST_TXCMD_2;
			end else begin
				// write reg
				// immediate only for now
				phy_d_out <= tx_reg_data_wr;
				phy_d_next <= 0;
				state <= ST_TXCMD_1;	// assert STP
			end
		end
		
		if(~tx_cmd_code[1]) begin
			// transmit packet
			// can't afford to dally around
			state <= state_next;
		end
	end
	
	ST_TXCMD_1: begin
		// assert STP on reg write
		phy_stp <= 1'b1;
		state <= state_next;
	end
	ST_TXCMD_2: begin
		// latch reg read
		if(phy_dir) state <= ST_TXCMD_3;
	end 
	ST_TXCMD_3: begin
		// read value from PHY
		tx_reg_data_rd <= phy_d;
		state <= state_next;
	end
	
	
	// TODO
	ST_PKT_0: begin
		// accept packet data
		tx_cmd_code <= TX_CMD_XMIT_PID;
		tx_pid <= pkt_in_byte[3:0];
		//{pkt_in_byte[0], pkt_in_byte[1], pkt_in_byte[2], pkt_in_byte[3]};
		// call TXCMD
		state <= ST_TXCMD_0;
		state_next <= ST_PKT_1;
	end
	ST_PKT_1: begin
		state <= ST_IDLE;
		
	end
	
	
	endcase
	
	if(~reset_2) begin
		state <= ST_RST_0;
	end
end
	
endmodule
	
	