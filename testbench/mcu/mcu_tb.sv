// mcu_tb.sv: self-checking unit test of the timer, watchdog, I2C master and RTC of src/uncore/mcu
// (the chip's cocotb tests drive them through mcu_apb and the pads).  Run with `make` here.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module mcu_tb;
  logic clk = 0, resetn = 0;
  always #5 clk = ~clk;

  int errors = 0;
  task automatic check(input string what, input int got, input int want);
    if (got !== want) begin errors++; $display("FAIL: %s: got %0d (0x%0h), expected %0d (0x%0h)", what, got, got, want, want); end
  endtask

  // one APB master shared by the four peripherals, each with its own select
  logic [3:0]  psel = 0;
  logic        pwrite = 0, penable = 0;
  logic [7:0]  paddr = 0;
  logic [31:0] pwdata = 0;
  logic [31:0] prdata [4];

  task automatic wr(input int p, input int a, input int d);
    @(posedge clk); psel <= 4'(1 << p); pwrite <= 1; paddr <= 8'(a); pwdata <= d; penable <= 0;
    @(posedge clk); penable <= 1;
    @(posedge clk); psel <= 0; penable <= 0; pwrite <= 0;
  endtask
  task automatic rd(input int p, input int a, output int d);
    @(posedge clk); psel <= 4'(1 << p); pwrite <= 0; paddr <= 8'(a); penable <= 0;
    @(posedge clk); penable <= 1;
    #1 d = prdata[p];
    @(posedge clk); psel <= 0; penable <= 0;
  endtask

  // ---- timer ----
  logic [3:0] cap_in = 0, pwm_out, pwm_en;
  logic       timer_intr;
  timer_apb timer(.PCLK(clk), .PRESETn(resetn), .PSEL(psel[0]), .PWRITE(pwrite), .PENABLE(penable),
    .PADDR(paddr), .PWDATA(pwdata), .PRDATA(prdata[0]), .CaptureIn(cap_in), .PWMOut(pwm_out),
    .PWMEn(pwm_en), .Intr(timer_intr));

  // ---- watchdog ----
  logic wdt_intr, wdt_reset;
  wdt_apb wdt(.PCLK(clk), .PRESETn(resetn), .PSEL(psel[1]), .PWRITE(pwrite), .PENABLE(penable),
    .PADDR(paddr), .PWDATA(pwdata), .PRDATA(prdata[1]), .Intr(wdt_intr), .ResetReq(wdt_reset));

  // ---- I2C with a slave at address 0x50 ----
  tri1  scl, sda;
  logic scl_drive, sda_drive, i2c_intr;
  logic slave_sda_low = 0;
  assign scl = scl_drive ? 1'b0 : 1'bz;
  assign sda = (sda_drive | slave_sda_low) ? 1'b0 : 1'bz;
  i2c_apb i2c(.PCLK(clk), .PRESETn(resetn), .PSEL(psel[2]), .PWRITE(pwrite), .PENABLE(penable),
    .PADDR(paddr), .PWDATA(pwdata), .PRDATA(prdata[2]), .SCLIn(scl), .SDAIn(sda),
    .SCLDrive(scl_drive), .SDADrive(sda_drive), .Intr(i2c_intr));

  // the slave: address 0x50, stores the bytes written to it, answers reads with 0xA5, stretches SCL
  // low for a while after the address byte
  logic [7:0] slave_got [8];
  int         slave_n = 0, slave_starts = 0, slave_stops = 0;
  logic       slave_stretch = 0;
  logic       scl_slave_low = 0, stopped = 0;
  always @(posedge sda) if (scl === 1'b1) begin stopped <= 1; slave_stops++; end
  always @(negedge sda) if (scl === 1'b1) stopped <= 0;
  assign scl = scl_slave_low ? 1'b0 : 1'bz;
  initial begin : slave
    logic [7:0] sh;
    logic       rw, done;
    forever begin
      @(negedge sda iff scl === 1'b1); // START
      slave_starts++;
      sh = 0;
      for (int b = 0; b < 8; b++) begin @(posedge scl); sh = {sh[6:0], sda}; if (b < 7) @(negedge scl); end
      rw = sh[0];
      @(negedge scl);
      if (sh[7:1] == 7'h50) begin
        slave_sda_low = 1; // ACK
        if (slave_stretch) begin
          scl_slave_low = 1;
          repeat (40) @(posedge clk);
          scl_slave_low = 0;
        end
        #1; if (scl !== 1'b1) @(posedge scl); // the release may already have raised SCL
        @(negedge scl);
        slave_sda_low = 0;
        if (!rw) begin
          // receive bytes until the STOP
          done = 0;
          while (!done) begin
            sh = 0;
            for (int b = 0; b < 8 && !done; b++) begin
              @(posedge scl);
              sh = {sh[6:0], sda};
              @(negedge scl or posedge stopped);
              if (stopped) done = 1;
            end
            if (!done) begin
              slave_got[slave_n++ % 8] = sh;
              slave_sda_low = 1; @(posedge scl); @(negedge scl); slave_sda_low = 0;
            end
          end
        end else begin
          // send 0xA5 and look at the master's ack
          sh = 8'hA5;
          for (int b = 0; b < 8; b++) begin
            slave_sda_low = ~sh[7-b];
            @(posedge scl); @(negedge scl);
          end
          slave_sda_low = 0;
          @(posedge scl); @(negedge scl); // the master's NACK
          if (!stopped) @(posedge stopped);
        end
      end
    end
  end

  // ---- RTC ----
  logic rtc_intr;
  rtc_apb rtc(.PCLK(clk), .PRESETn(resetn), .PSEL(psel[3]), .PWRITE(pwrite), .PENABLE(penable),
    .PADDR(paddr), .PWDATA(pwdata), .PRDATA(prdata[3]), .Intr(rtc_intr));

  int v, hi, lo;

  task automatic i2c_wait(output int status);
    int s;
    s = 1;
    while (s[0]) rd(2, 'h10, s);
    status = s;
  endtask

  initial begin
    repeat (4) @(posedge clk);
    resetn = 1;
    repeat (2) @(posedge clk);

    // ---------------- timer: PWM ----------------
    wr(0, 'h08, 9);          // ARR: period of 10 ticks
    wr(0, 'h20, 3);          // channel 0: high for 3 ticks
    wr(0, 'h24, 0);          // channel 1: always low
    wr(0, 'h28, 100);        // channel 2: always high
    wr(0, 'h4C, 'h8 | 0);    // channel 3: inverted, CCR 0 -> always high
    wr(0, 'h14, 'h1);        // overflow interrupt
    wr(0, 'h00, 1);
    hi = 0; lo = 0;
    for (int i = 0; i < 100; i++) begin
      @(posedge clk);
      if (pwm_out[0]) hi++; else lo++;
      if (pwm_out[1]) errors++;
      if (!pwm_out[2]) errors++;
      if (!pwm_out[3]) errors++;
    end
    check("pwm0 high clocks in 100", hi, 30);
    check("pwm0 low clocks in 100", lo, 70);
    check("timer overflow interrupt", timer_intr, 1);
    wr(0, 'h10, 'h1F);
    check("timer interrupt cleared", timer_intr, 0);
    check("pwm enabled", pwm_en, 4'hF);

    // prescaler: ticks every 4 clocks
    wr(0, 'h00, 0);
    wr(0, 'h0C, 0);
    wr(0, 'h08, 1000);
    wr(0, 'h04, 3);
    wr(0, 'h00, 1);
    repeat (40) @(posedge clk);
    rd(0, 'h0C, v);
    if (v < 9 || v > 11) begin errors++; $display("FAIL: prescaled count %0d", v); end

    // one-shot: stops at overflow
    wr(0, 'h00, 0); wr(0, 'h04, 0); wr(0, 'h0C, 0); wr(0, 'h08, 5); wr(0, 'h10, 'h1F);
    wr(0, 'h00, 3);
    repeat (30) @(posedge clk);
    rd(0, 'h00, v); check("oneshot cleared EN", v, 2);
    rd(0, 'h10, v); check("oneshot overflow flag", v & 1, 1);

    // ---------------- timer: capture ----------------
    wr(0, 'h00, 0); wr(0, 'h0C, 0); wr(0, 'h08, 1000); wr(0, 'h10, 'h1F);
    wr(0, 'h44, 'b011);      // channel 1: capture, rising edge
    wr(0, 'h48, 'b101);      // channel 2: capture, falling edge
    wr(0, 'h14, 'h1E);
    check("capture channel leaves pad as input", pwm_en[1], 0);
    wr(0, 'h00, 1);
    repeat (20) @(posedge clk);
    cap_in[1] = 1;           // rising edge on channel 1
    repeat (10) @(posedge clk);
    check("capture 1 interrupt", timer_intr, 1);
    rd(0, 'h24, v);
    if (v < 20 || v > 40) begin errors++; $display("FAIL: captured value %0d", v); end
    rd(0, 'h10, v); check("capture 1 status", v & 'h4, 'h4);
    cap_in[2] = 1;           // a rising edge on channel 2 must not capture
    repeat (10) @(posedge clk);
    rd(0, 'h10, v); check("channel 2 ignores rising edge", v & 'h8, 0);
    cap_in[2] = 0;
    repeat (10) @(posedge clk);
    rd(0, 'h10, v); check("channel 2 falling edge", v & 'h8, 'h8);
    wr(0, 'h00, 0);

    // ---------------- watchdog ----------------
    wr(1, 'h04, 20);
    wr(1, 'h14, 0);
    wr(1, 'h00, 3);          // EN, IE
    wr(1, 'h00, 2);          // EN sticks (IE stays on)
    rd(1, 'h00, v); check("wdt EN sticky", v & 1, 1);
    repeat (10) @(posedge clk);
    wr(1, 'h0C, 32'h5A1CE55A); // kick before the timeout
    repeat (15) @(posedge clk);
    wr(1, 'h0C, 32'h12345678); // wrong key: ignored
    check("wdt no interrupt before the timeout", wdt_intr, 0);
    repeat (15) @(posedge clk);
    check("wdt first timeout interrupts", wdt_intr, 1);
    check("wdt no reset on first timeout", wdt_reset, 0);
    wr(1, 'h0C, 32'h5A1CE55A);
    check("kick clears the flag", wdt_intr, 0);
    repeat (60) @(posedge clk);
    check("wdt resets on the second timeout", wdt_reset, 1);
    resetn = 0; repeat (3) @(posedge clk); resetn = 1; repeat (3) @(posedge clk);
    check("reset clears the wdt request", wdt_reset, 0);
    rd(1, 'h00, v); check("reset clears wdt EN", v, 0);

    // ---------------- RTC ----------------
    wr(3, 'h04, 3);          // a tick every 4 clocks
    wr(3, 'h0C, 5);
    wr(3, 'h00, 3);
    repeat (5) @(posedge clk);
    check("rtc not yet", rtc_intr, 0);
    repeat (24) @(posedge clk);
    check("rtc alarm", rtc_intr, 1);
    rd(3, 'h08, v); if (v < 5 || v > 10) begin errors++; $display("FAIL: rtc time %0d", v); end
    wr(3, 'h10, 1);
    check("rtc flag cleared", rtc_intr, 0);
    wr(3, 'h14, 10);         // periodic: next alarm 10 ticks later
    wr(3, 'h08, 0);
    wr(3, 'h0C, 8);
    repeat (40) @(posedge clk);
    check("rtc periodic alarm 1", rtc_intr, 1);
    wr(3, 'h10, 1);
    rd(3, 'h0C, v); check("rtc alarm advanced by the period", v, 18);
    repeat (40) @(posedge clk);
    check("rtc periodic alarm 2", rtc_intr, 1);

    // ---------------- I2C ----------------
    wr(2, 'h00, 3);          // PRE: 4 clocks per step
    wr(2, 'h04, 3);          // EN, IE
    slave_stretch = 1;
    slave_stops = 0;
    wr(2, 'h08, 8'hA0);      // address 0x50, write
    wr(2, 'h0C, 'b01001);    // START + WRITE
    i2c_wait(v);
    check("i2c address acknowledged", v & 2, 0);
    check("i2c interrupt", i2c_intr, 1);
    wr(2, 'h10, 4);
    check("i2c interrupt cleared", i2c_intr, 0);
    wr(2, 'h08, 8'h12);
    wr(2, 'h0C, 'b01000);    // WRITE
    i2c_wait(v);
    check("i2c data acknowledged", v & 2, 0);
    wr(2, 'h08, 8'h34);
    wr(2, 'h0C, 'b01010);    // WRITE + STOP
    i2c_wait(v);
    check("slave bytes", slave_n, 2);
    check("slave byte 0", slave_got[0], 8'h12);
    check("slave byte 1", slave_got[1], 8'h34);
    check("slave saw one start", slave_starts, 1);
    check("slave saw a stop", slave_stops, 1);

    // a wrong address is not acknowledged
    wr(2, 'h08, 8'hA2);      // address 0x51
    wr(2, 'h0C, 'b01011);    // START + WRITE + STOP
    i2c_wait(v);
    check("i2c wrong address not acknowledged", v & 2, 2);

    // read: START + write the read address, then READ + NACK + STOP
    slave_stretch = 0;
    wr(2, 'h08, 8'hA1);
    wr(2, 'h0C, 'b01001);
    i2c_wait(v);
    check("i2c read address acknowledged", v & 2, 0);
    wr(2, 'h0C, 'b10110);    // READ + NACK + STOP
    i2c_wait(v);
    rd(2, 'h08, v);
    check("i2c byte read", v, 8'hA5);

    if (errors == 0) $display("PASS: timer, watchdog, RTC and I2C");
    else             $display("FAIL: %0d errors", errors);
    $finish;
  end

  initial begin #5_000_000; $display("FAIL: timeout"); $finish; end
endmodule
