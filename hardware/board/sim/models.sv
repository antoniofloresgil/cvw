// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Behavioural models of the parts of the test board (hardware/board/mcu_board.py) that take part in
// a digital simulation.  gen_board.py instantiates them from the schematic's netlist, so the wiring
// under test is the board's; these models only play the parts.
//
// They model what the firmware and the debugger see, not the analogue side or the timing of the
// data sheets, with these shortcuts:
//   - the reset supervisor's 140 ms timeout is scaled down (TIMEOUT_NS), as a simulation of the chip
//     runs at about 0.4 ms per second
//   - the EEPROM finishes a write at once (the data sheet's 5 ms write cycle is not modelled)
//   - analogue pins (the ADS1115 inputs, the DAC output) are not connected; the ADS1115 returns a
//     value that the test sets
// Nets resolve without strengths in Verilator: a test must not make two devices drive one net.

`timescale 1ns/1ps
/* verilator lint_off MULTIDRIVEN */

// ---------------------------------------------------------------------------------------------
// Oscillator ASE-xxxMHz: a CMOS clock while EN is high
module osc #(parameter real FREQ_MHZ = 18.432) (input en, output out);
  localparam real HALF = 500.0 / FREQ_MHZ;       // ns
  reg clk = 0;
  always #(HALF) clk = ~clk;
  assign out = en ? clk : 1'bz;
endmodule

// ---------------------------------------------------------------------------------------------
// MAX811: reset supervisor.  RESET (push-pull, active low) is asserted while VCC is low or MR is
// low, and for TIMEOUT_NS after both are released (after power-up too).  MR has an internal pull-up.
module max811 #(parameter real TIMEOUT_NS = 20000.0) (input vcc, input mr, output reset_n);
  realtime release_at /*verilator public_flat_rw*/ = 0.0;
  reg rst /*verilator public_flat_rw*/ = 1;
  initial release_at = $realtime + TIMEOUT_NS;
  // the simulator runs this block without a change on a resolved net, so compare with the last values
  reg mr_q = 1, vcc_q = 1;
  always @(mr or vcc) if (mr != mr_q || vcc != vcc_q) begin
    mr_q = mr; vcc_q = vcc;
    if (!mr || !vcc) release_at = 1.0e30;
    else release_at = $realtime + TIMEOUT_NS;
  end
  always begin
    #(TIMEOUT_NS / 64.0);
    rst = !vcc || $realtime < release_at;
  end
  assign reset_n = rst ? 1'b0 : 1'b1;
endmodule

// ---------------------------------------------------------------------------------------------
// 74AHC541: octal buffer with two active-low enables
module ahc541 (input g1_n, input g2_n, input [7:0] a, output [7:0] y);
  assign y = (!g1_n && !g2_n) ? a : 8'bz;
endmodule

// ---------------------------------------------------------------------------------------------
// LED: lit when the anode is high and the cathode low
module led (input a, input k, output on);
  assign on = a && !k;
endmodule

// ---------------------------------------------------------------------------------------------
// FT2232H seen from the board: Port A bits 0-4 and Port B bits 0-1 as the pins a JTAG adapter and a
// UART bridge use.  The test sets *_out and *_oe (1: drive the pin) and reads *_in.  Pin 0 of port A
// is TCK, 1 TDI, 2 TDO, 3 TMS, 4 the system reset; port B pin 0 is TXD (to the chip), 1 RXD.
module ft2232 (inout adbus0, inout adbus1, inout adbus2, inout adbus3, inout adbus4,
               inout bdbus0, inout bdbus1);
  reg  [7:0] adbus_out /*verilator public_flat_rw*/ = 8'h00, adbus_oe /*verilator public_flat_rw*/ = 8'h00,
             bdbus_out /*verilator public_flat_rw*/ = 8'h01, bdbus_oe /*verilator public_flat_rw*/ = 8'h01;
  wire [7:0] adbus_in /*verilator public_flat_rw*/ = {3'b0, adbus4, adbus3, adbus2, adbus1, adbus0};
  wire [7:0] bdbus_in = {6'b0, bdbus1, bdbus0};
  assign adbus0 = adbus_oe[0] ? adbus_out[0] : 1'bz;
  assign adbus1 = adbus_oe[1] ? adbus_out[1] : 1'bz;
  assign adbus2 = adbus_oe[2] ? adbus_out[2] : 1'bz;
  assign adbus3 = adbus_oe[3] ? adbus_out[3] : 1'bz;
  assign adbus4 = adbus_oe[4] ? adbus_out[4] : 1'bz;
  assign bdbus0 = bdbus_oe[0] ? bdbus_out[0] : 1'bz;
  assign bdbus1 = bdbus_oe[1] ? bdbus_out[1] : 1'bz;
endmodule

// ---------------------------------------------------------------------------------------------
// W25Q32JV SPI flash (the SOIC-8 board part), standard SPI mode 0: Read (03h), Fast Read (0Bh)
// and JEDEC ID (9Fh).  SIZE bytes are modelled, erased (FFh); the test writes the image.  With
// /HOLD low the device ignores the clock and releases DO.
module w25q32 #(parameter SIZE = 65536) (input cs_n, input clk, input di, output do_, input hold_n, input wp_n);
  reg [7:0] mem [0:SIZE-1] /*verilator public_flat_rw*/;
  initial for (int i = 0; i < SIZE; i++) mem[i] = 8'hFF;

  localparam [2:0] CMD = 0, ADDR = 1, DUMMY = 2, DATA = 3, ID = 4;
  reg [2:0]  state;
  reg [7:0]  cmd, sh;
  reg [23:0] addr;
  reg [4:0]  nbits;
  reg [2:0]  obit;
  reg [7:0]  obyte;
  reg        out = 1'b1, driving = 1'b0;
  assign do_ = (!cs_n && driving) ? out : 1'bz;

  wire active = !cs_n && hold_n;

  always @(posedge cs_n) begin state <= CMD; nbits <= 0; driving <= 0; end
  always @(negedge cs_n) begin state <= CMD; nbits <= 0; driving <= 0; end

  // bits come in on the rising edge of CLK
  always @(posedge clk) if (active) begin
    case (state)
      CMD: begin
        sh <= {sh[6:0], di};
        nbits <= nbits + 1;
        if (nbits == 7) begin
          cmd <= {sh[6:0], di};
          nbits <= 0;
          state <= ({sh[6:0], di} == 8'h9F) ? ID : ADDR;
        end
      end
      ADDR: begin
        addr <= {addr[22:0], di};
        nbits <= nbits + 1;
        if (nbits == 23) begin
          nbits <= 0;
          state <= (cmd == 8'h0B) ? DUMMY : DATA;
          obit <= 0;
        end
      end
      DUMMY: begin
        nbits <= nbits + 1;
        if (nbits == 7) begin nbits <= 0; state <= DATA; obit <= 0; end
      end
      default: ;
    endcase
  end

  // bits go out on the falling edge of CLK, the first one right after the last address bit
  reg [7:0] idbyte;
  always @(negedge clk) if (active) begin
    case (state)
      DATA: begin
        if (cmd == 8'h03 || cmd == 8'h0B) begin
          obyte = mem[addr % SIZE];
          driving <= 1; out <= obyte[7 - obit];
          obit <= obit + 1;
          if (obit == 7) addr <= addr + 1;
        end
      end
      ID: begin
        driving <= 1;
        idbyte = (nbits < 8) ? 8'hEF : (nbits < 16) ? 8'h40 : 8'h16;
        out <= idbyte[7 - (nbits % 8)];
        nbits <= nbits + 1;
      end
      default: ;
    endcase
  end
endmodule

// ---------------------------------------------------------------------------------------------
// I2C target: start and stop detection, the address byte, and bytes in both directions.  A device
// puts its behaviour around it: rx_t toggles for every byte the master writes after the address
// (rx_data), tx_t for every byte it read (tx_data is the byte to send next, which the device keeps
// current), addr_t when the address matched (rw: 1 = read), stop_t at a STOP and start_t at a
// START or repeated START.  Devices wait for these with edge events: a block sensitive to the level of
// a toggling signal runs without a change in the simulator.
module i2c_target (input [6:0] addr, input rx_ack, input [7:0] tx_data, inout scl, inout sda,
                   output reg [7:0] rx_data, output reg rw,
                   output reg rx_t = 0, output reg tx_t = 0, output reg addr_t = 0,
                   output reg stop_t = 0, output reg start_t = 0);
  localparam [2:0] IDLE = 0, ADDR = 1, ACKA = 2, RX = 3, ACKD = 4, TX = 5, WACK = 6;
  reg [2:0] state /*verilator public_flat_rw*/ = IDLE;
  reg [3:0] cnt /*verilator public_flat_rw*/;
  reg [7:0] sh;
  reg       sda_o /*verilator public_flat_rw*/ = 1, nack;
  assign sda = sda_o ? 1'bz : 1'b0;

  always @(negedge sda) if (scl) begin state <= ADDR; cnt <= 0; sda_o <= 1; start_t <= ~start_t; end
  always @(posedge sda) if (scl) begin state <= IDLE; sda_o <= 1; stop_t <= ~stop_t; end

  always @(posedge scl) begin
    case (state)
      ADDR, RX: if (cnt < 8) begin sh <= {sh[6:0], sda}; cnt <= cnt + 1; end
      WACK: begin nack <= sda; if (!sda) tx_t <= ~tx_t; end
      default: ;
    endcase
  end

  always @(negedge scl) begin
    case (state)
      ADDR: if (cnt == 8) begin
        if (sh[7:1] == addr) begin sda_o <= 0; rw <= sh[0]; state <= ACKA; addr_t <= ~addr_t; end
        else state <= IDLE;
      end
      ACKA: begin
        cnt <= 0;
        if (rw) begin sh <= tx_data; sda_o <= tx_data[7]; cnt <= 1; state <= TX; end
        else begin sda_o <= 1; state <= RX; end
      end
      RX: if (cnt == 8) begin
        rx_data <= sh; rx_t <= ~rx_t;
        sda_o <= !rx_ack; state <= ACKD;
      end
      ACKD: begin sda_o <= 1; cnt <= 0; state <= RX; end
      TX: begin
        if (cnt < 8) begin sda_o <= sh[7 - cnt]; cnt <= cnt + 1; end
        else begin sda_o <= 1; state <= WACK; end
      end
      WACK: begin
        if (!nack) begin sh <= tx_data; sda_o <= tx_data[7]; cnt <= 1; state <= TX; end
        else begin sda_o <= 1; state <= IDLE; end
      end
      default: ;
    endcase
  end
endmodule

// ---------------------------------------------------------------------------------------------
// 24LC256: 32 KiB I2C EEPROM at 0x50 + {A2, A1, A0}; byte and page writes (64-byte pages), current
// address, random and sequential reads
module eeprom24 (input a0, input a1, input a2, input wp, inout scl, inout sda);
  reg [7:0] mem [0:32767] /*verilator public_flat_rw*/;
  initial for (int i = 0; i < 32768; i++) mem[i] = 8'hFF;
  reg [14:0] ptr = 0;
  reg [1:0]  nadr;                     // address bytes received in this write transaction
  reg [7:0]  hi;
  wire [7:0] rx_data, tx_data = mem[ptr];
  wire       rw, rx_t, tx_t, addr_t, stop_t, start_t;
  i2c_target t(.addr({4'b1010, a2, a1, a0}), .rx_ack(1'b1), .tx_data, .scl, .sda, .rx_data, .rw,
               .rx_t, .tx_t, .addr_t, .stop_t, .start_t);
  always @(posedge addr_t or negedge addr_t) nadr = 0;
  always @(posedge rx_t or negedge rx_t) begin
    if (nadr == 0) begin hi = rx_data; nadr = 1; end
    else if (nadr == 1) begin ptr = {hi[6:0], rx_data}; nadr = 2; end
    else begin
      if (!wp) mem[ptr] = rx_data;
      ptr[5:0] = ptr[5:0] + 6'd1;      // a page write wraps inside its 64-byte page
    end
  end
  always @(posedge tx_t or negedge tx_t) ptr = ptr + 15'd1;
endmodule

// ---------------------------------------------------------------------------------------------
// TMP102 at 0x48 + (ADD0 high: 1): pointer register, temperature (a test sets it), configuration,
// T_LOW and T_HIGH
module tmp102 (input add0, inout scl, inout sda);
  reg [15:0] regs [0:3];
  initial begin regs[0] = 16'h1900; regs[1] = 16'h60A0; regs[2] = 16'h4B00; regs[3] = 16'h5000; end
  reg [1:0]  ptr = 0;
  reg        phase;                    // 0: next byte is the pointer, 1/2: high/low byte of a register
  reg [1:0]  wbyte;
  reg        hibyte = 1;
  wire [7:0] rx_data, tx_data = hibyte ? regs[ptr][15:8] : regs[ptr][7:0];
  wire       rw, rx_t, tx_t, addr_t, stop_t, start_t;
  i2c_target t(.addr({6'b100100, add0}), .rx_ack(1'b1), .tx_data, .scl, .sda, .rx_data, .rw,
               .rx_t, .tx_t, .addr_t, .stop_t, .start_t);
  always @(posedge addr_t or negedge addr_t) begin wbyte = 0; hibyte = 1; end
  always @(posedge rx_t or negedge rx_t) begin
    if (wbyte == 0) ptr = rx_data[1:0];
    else if (wbyte == 1) regs[ptr][15:8] = rx_data;
    else regs[ptr][7:0] = rx_data;
    wbyte = wbyte + 1;
  end
  always @(posedge tx_t or negedge tx_t) hibyte = ~hibyte;
endmodule

// ---------------------------------------------------------------------------------------------
// ADS1115 at 0x48 + ADDR (GND 0, VDD 1): pointer, conversion (the test sets `conversion`),
// configuration (reset value 8583h), thresholds
module ads1115 (input addr_pin, inout scl, inout sda);
  reg [15:0] conversion = 16'h0000;
  reg [15:0] config_ = 16'h8583, lo = 16'h8000, hi = 16'h7FFF;
  reg [1:0]  ptr = 0;
  reg [1:0]  wbyte;
  reg        hibyte = 1;
  wire [15:0] cur = (ptr == 0) ? conversion : (ptr == 1) ? config_ : (ptr == 2) ? lo : hi;
  wire [7:0] rx_data, tx_data = hibyte ? cur[15:8] : cur[7:0];
  wire       rw, rx_t, tx_t, addr_t, stop_t, start_t;
  i2c_target t(.addr({6'b100100, addr_pin}), .rx_ack(1'b1), .tx_data, .scl, .sda, .rx_data, .rw,
               .rx_t, .tx_t, .addr_t, .stop_t, .start_t);
  always @(posedge addr_t or negedge addr_t) begin wbyte = 0; hibyte = 1; end
  always @(posedge rx_t or negedge rx_t) begin
    case (wbyte)
      0: ptr = rx_data[1:0];
      1: case (ptr) 1: config_[15:8] = rx_data; 2: lo[15:8] = rx_data; 3: hi[15:8] = rx_data; default: ; endcase
      default: case (ptr) 1: config_[7:0] = rx_data; 2: lo[7:0] = rx_data; 3: hi[7:0] = rx_data; default: ; endcase
    endcase
    wbyte = wbyte + 1;
  end
  always @(posedge tx_t or negedge tx_t) hibyte = ~hibyte;
endmodule

// ---------------------------------------------------------------------------------------------
// MCP4725 at 0x60 + A0: fast-mode write (two bytes) and write-DAC-register (three bytes); a read
// returns the status byte, then the DAC register in two bytes
module mcp4725 (input a0, inout scl, inout sda);
  reg [11:0] dac /*verilator public_flat_rw*/ = 12'h800;            // power-on value read from its EEPROM
  reg [1:0]  pd = 0;
  reg [1:0]  wbyte;
  reg [7:0]  first;
  reg [1:0]  rbyte;
  wire [7:0] rx_data;
  wire [7:0] tx_data = (rbyte == 0) ? {1'b1, 1'b1, 3'b0, pd, 1'b0} :
                       (rbyte == 1) ? dac[11:4] : {dac[3:0], 4'b0};
  wire       rw, rx_t, tx_t, addr_t, stop_t, start_t;
  i2c_target t(.addr({6'b110000, a0}), .rx_ack(1'b1), .tx_data, .scl, .sda, .rx_data, .rw,
               .rx_t, .tx_t, .addr_t, .stop_t, .start_t);
  always @(posedge addr_t or negedge addr_t) begin wbyte = 0; rbyte = 0; end
  always @(posedge rx_t or negedge rx_t) begin
    if (wbyte == 0) begin
      first = rx_data;
      if (rx_data[7:6] == 2'b00) pd = rx_data[5:4];          // fast mode: D11-D8 here, D7-D0 next
    end else if (wbyte == 1) begin
      if (first[7:6] == 2'b00) dac = {first[3:0], rx_data};
      else if (first[7:5] == 3'b010 || first[7:5] == 3'b011) dac[11:4] = rx_data;
      if (first[7:5] == 3'b010 || first[7:5] == 3'b011) pd = first[2:1];
    end else if (first[7:5] == 3'b010 || first[7:5] == 3'b011) dac[3:0] = rx_data[7:4];
    if (wbyte != 3) wbyte = wbyte + 1;
  end
  always @(posedge tx_t or negedge tx_t) if (rbyte != 3) rbyte = rbyte + 1;
endmodule
