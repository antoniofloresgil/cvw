///////////////////////////////////////////
// tb_extbussplit.sv
//
// Purpose: Self-checking test of the external-bus split used by the open-source
//          FPGA flow: extbussplit plus the two ahbwishbonebridge instances, with
//          a slow Wishbone slave for the DDR3 data path and a LiteX-like one for
//          the control registers.  Pipelined AHB transfers alternate between the
//          two windows, including back-to-back transfers on the same side, and a
//          transfer outside the external region must reach neither.
//
// Run:     verilator --binary --timing --Wno-fatal -Mdir <dir> --top-module tb_extbussplit \
//            tests/fpga/tb_extbussplit.sv fpga/src/extbussplit.sv src/uncore/ahbwishbonebridge.sv
//          <dir>/Vtb_extbussplit
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module tb_extbussplit;
  localparam CTRL_SEL_BIT = 27;
  localparam N = 16;   // capacity of the transfer list

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;

  // AHB master side
  logic [31:0] HADDR = '0, HWDATA;
  logic [1:0]  HTRANS = 2'b00;
  logic        HWRITE = 1'b0;
  logic        HSELEXT;
  logic        HREADY, HRESP;
  logic [31:0] HRDATA;

  logic        HSELDDR, HSELCtrl;
  logic [31:0] HRDATADDR, HRDATACtrl;
  logic        HREADYDDR, HREADYCtrl, HRESPDDR, HRESPCtrl;

  assign HSELEXT = HTRANS[1] & (HADDR[31:28] == 4'h4);

  extbussplit #(.DATA_WIDTH(32)) split (
    .HCLK(clk), .HRESETn(rstn), .HSELEXT, .SelCtrl(HADDR[CTRL_SEL_BIT]),
    .HREADY, .HTRANS, .HSELDDR, .HSELCtrl,
    .HRDATADDR, .HRDATACtrl, .HREADYDDR, .HREADYCtrl, .HRESPDDR, .HRESPCtrl,
    .HRDATAEXT(HRDATA), .HREADYEXT(HREADY), .HRESPEXT(HRESP)
  );

  // DDR side: 29-bit byte address, 4-cycle slave
  logic [26:0] d_adr;
  logic [31:0] d_dat_w, d_dat_r;
  logic [3:0]  d_sel;
  logic        d_we, d_cyc, d_stb, d_ack;
  ahbwishbonebridge #(.ADDR_WIDTH(29), .DATA_WIDTH(32)) ddrbridge (
    .HCLK(clk), .HRESETn(rstn), .HSEL(HSELDDR), .HADDR(HADDR[28:0]), .HTRANS, .HWRITE,
    .HWDATA, .HWSTRB(4'hF), .HREADY, .HREADYOUT(HREADYDDR), .HRDATA(HRDATADDR), .HRESP(HRESPDDR),
    .wb_adr(d_adr), .wb_dat_w(d_dat_w), .wb_sel(d_sel), .wb_we(d_we),
    .wb_cyc(d_cyc), .wb_stb(d_stb), .wb_dat_r(d_dat_r), .wb_ack(d_ack)
  );

  // Control side: 64 KiB window, 2-cycle slave
  logic [13:0] c_adr;
  logic [31:0] c_dat_w, c_dat_r;
  logic [3:0]  c_sel;
  logic        c_we, c_cyc, c_stb, c_ack;
  ahbwishbonebridge #(.ADDR_WIDTH(16), .DATA_WIDTH(32)) ctrlbridge (
    .HCLK(clk), .HRESETn(rstn), .HSEL(HSELCtrl), .HADDR(HADDR[15:0]), .HTRANS, .HWRITE,
    .HWDATA, .HWSTRB(4'hF), .HREADY, .HREADYOUT(HREADYCtrl), .HRDATA(HRDATACtrl), .HRESP(HRESPCtrl),
    .wb_adr(c_adr), .wb_dat_w(c_dat_w), .wb_sel(c_sel), .wb_we(c_we),
    .wb_cyc(c_cyc), .wb_stb(c_stb), .wb_dat_r(c_dat_r), .wb_ack(c_ack)
  );

  logic [31:0] ddrmem [0:255], ctrlmem [0:255];
  int dcnt = 0, ccnt = 0, dack = 0, cack = 0;
  always_ff @(posedge clk) begin
    d_ack <= 1'b0;
    c_ack <= 1'b0;
    if (!rstn) begin dcnt <= 0; ccnt <= 0; end
    else begin
      if (d_cyc & d_stb & ~d_ack) dcnt <= dcnt + 1; else if (!d_cyc) dcnt <= 0;
      if (d_cyc & d_stb & dcnt == 3) begin
        d_ack <= 1'b1;
        if (d_we) ddrmem[d_adr[7:0]] <= d_dat_w; else d_dat_r <= ddrmem[d_adr[7:0]];
        dcnt <= 0;
      end
      if (c_cyc & c_stb & ~c_ack) ccnt <= ccnt + 1; else if (!c_cyc) ccnt <= 0;
      if (c_cyc & c_stb & ccnt == 1) begin
        c_ack <= 1'b1;
        if (c_we) ctrlmem[c_adr[7:0]] <= c_dat_w; else c_dat_r <= ctrlmem[c_adr[7:0]];
        ccnt <= 0;
      end
      if (d_ack) dack <= dack + 1;
      if (c_ack) cack <= cack + 1;
      if (d_cyc & c_cyc) begin $display("FAIL: both windows active"); $finish; end
    end
  end

  // Transfer list
  logic [31:0] ta [N], td [N], te [N];
  logic        tw [N];
  int          ntx = 0, nddr = 0, nctrl = 0;
  task automatic add(input logic [31:0] a, input logic w, input logic [31:0] d, input logic [31:0] e);
    ta[ntx] = a; tw[ntx] = w; td[ntx] = d; te[ntx] = e; ntx++;
    if (a[31:28] != 4'h4) ;        // outside the external region: no Wishbone access
    else if (a[CTRL_SEL_BIT]) nctrl++; else nddr++;
  endtask

  int ap = 0;       // next transfer to start
  int cur = -1;     // transfer in address phase
  int di = -1;      // transfer in data phase
  int errors = 0;
  bit done = 0, go = 0;
  assign HWDATA = (di >= 0 && tw[di]) ? td[di] : 32'hx;

  always_ff @(posedge clk) if (go && !done) begin
    if (HREADY) begin
      if (di >= 0 && !tw[di] && HRDATA !== te[di]) begin
        $display("FAIL: read %h expected %h got %h", ta[di], te[di], HRDATA);
        errors++;
      end
      if (di >= 0 && HRESP) begin $display("FAIL: HRESP"); errors++; end
      di = cur;                    // the address phase just ended
      if (ap < ntx) begin
        HADDR <= ta[ap]; HWRITE <= tw[ap]; HTRANS <= 2'b10; cur = ap; ap = ap + 1;
      end else begin
        HTRANS <= 2'b00; cur = -1;
      end
      if (cur < 0 && di < 0) done = 1;
    end
  end

  initial begin
    for (int i = 0; i < 256; i++) begin ddrmem[i] = '0; ctrlmem[i] = '0; end
    add(32'h4000_0010, 1, 32'h1111_1111, 'x);
    add(32'h4800_0004, 1, 32'h2222_2222, 'x);
    add(32'h4000_0014, 1, 32'h3333_3333, 'x);
    add(32'h4000_0010, 0, 'x, 32'h1111_1111);
    add(32'h4800_0004, 0, 'x, 32'h2222_2222);
    add(32'h4000_0014, 0, 'x, 32'h3333_3333);
    add(32'h4000_0010, 0, 'x, 32'h1111_1111);
    add(32'h4000_0014, 0, 'x, 32'h3333_3333);
    add(32'h1800_0008, 1, 32'h5555_5555, 'x);   // another slave, CSR select bit set
    add(32'h4800_0008, 1, 32'h4444_4444, 'x);
    add(32'h4800_0008, 0, 'x, 32'h4444_4444);
    add(32'h4800_0004, 0, 'x, 32'h2222_2222);
    add(32'h4000_0010, 0, 'x, 32'h1111_1111);
    repeat (4) @(posedge clk);
    rstn = 1;
    repeat (3) @(posedge clk);
    @(negedge clk) go = 1;   // the driver starts the first transfer
    fork
      begin wait (done); end
      begin repeat (2000) @(posedge clk); $display("FAIL: timeout"); errors++; end
    join_any
    repeat (4) @(posedge clk);
    if (dack != nddr) begin $display("FAIL: DDR acks %0d expected %0d", dack, nddr); errors++; end
    if (cack != nctrl) begin $display("FAIL: ctrl acks %0d expected %0d", cack, nctrl); errors++; end
    if (errors == 0) $display("PASS: %0d transfers (%0d DDR, %0d control)", ntx, nddr, nctrl);
    else $display("FAIL: %0d errors", errors);
    $finish;
  end
endmodule
