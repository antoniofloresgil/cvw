// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Hart-owned LR/SC reservations, independent of arbitration and cache storage.
// Events are sampled at the ordering point, not when a hart request is queued.
module multicore_reservations import cvw::*; #(
  parameter cvw_t P,
  parameter int unsigned NCORES = 2
)(
  input logic HCLK, HRESETn,
  input logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] QueryOwner,
  input logic [P.PA_BITS-1:0] QueryAddr,
  input logic [2:0] QuerySize,
  input logic QueryBlocked,
  output logic SCValid,
  input logic Issue,
  input logic [1:0] IssueOp,
  input logic Complete,
  input logic [(NCORES > 1 ? $clog2(NCORES) : 1)-1:0] CompleteOwner,
  input logic [P.PA_BITS-1:0] CompleteAddr,
  input logic [2:0] CompleteSize,
  input logic [1:0] CompleteOp,
  input logic CompleteWrite, CompleteError,
  input logic [NCORES-1:0] ReservationClear, LocalStoreCommit,
  input logic [NCORES-1:0][P.PA_BITS-1:0] LocalStoreAddr,
  output logic [NCORES-1:0] SCFail
);
  localparam OWNER_BITS = NCORES > 1 ? $clog2(NCORES) : 1;
  localparam GRANULE_BITS = $clog2(P.XLEN/8);
  logic [NCORES-1:0] Valid;
  logic [NCORES-1:0][P.PA_BITS-1:0] Addr;
  logic [NCORES-1:0][2:0] Size;

  assign SCValid = Valid[QueryOwner] && Addr[QueryOwner] == QueryAddr &&
    Size[QueryOwner] == QuerySize && !QueryBlocked;

  always_ff @(posedge HCLK) begin
    if (!HRESETn) begin
      Valid <= '0;
      Addr <= '0;
      Size <= '0;
      SCFail <= '0;
    end else begin
      if (Issue) begin
        if (IssueOp == COREBUS_LR || IssueOp == COREBUS_SC) Valid[QueryOwner] <= 1'b0;
        if (IssueOp == COREBUS_SC && !SCValid) SCFail[QueryOwner] <= 1'b1;
      end
      if (Complete) begin
        // Retain the SC result across unrelated replies and pipeline stalls.
        if (CompleteOp == COREBUS_SC) SCFail[CompleteOwner] <= CompleteError;
        if (CompleteOp == COREBUS_LR && !CompleteError) begin
          Valid[CompleteOwner] <= 1'b1;
          Addr[CompleteOwner] <= CompleteAddr;
          Size[CompleteOwner] <= CompleteSize;
        end
        if (CompleteWrite && !CompleteError)
          for (int h = 0; h < NCORES; h++)
            if (Addr[h][P.PA_BITS-1:GRANULE_BITS] == CompleteAddr[P.PA_BITS-1:GRANULE_BITS])
              Valid[h] <= 1'b0;
      end
      // Cross-home clears override installation in this home.
      for (int h = 0; h < NCORES; h++)
        if (ReservationClear[h]) Valid[h] <= 1'b0;
      // A same-edge LR installs a NEW address. Compare local commits against
      // that address, not the stale previous reservation left in the registers.
      for (int writer = 0; writer < NCORES; writer++)
        if (LocalStoreCommit[writer]) begin
          for (int h = 0; h < NCORES; h++)
            if ((Complete && !CompleteError && CompleteOp == COREBUS_LR && CompleteOwner == OWNER_BITS'(h)) ?
                (CompleteAddr[P.PA_BITS-1:GRANULE_BITS] == LocalStoreAddr[writer][P.PA_BITS-1:GRANULE_BITS]) :
                (Addr[h][P.PA_BITS-1:GRANULE_BITS] == LocalStoreAddr[writer][P.PA_BITS-1:GRANULE_BITS]))
              Valid[h] <= 1'b0;
          for (int peer = writer+1; peer < NCORES; peer++)
            assert (!(LocalStoreCommit[peer] &&
              LocalStoreAddr[writer][P.PA_BITS-1:GRANULE_BITS] == LocalStoreAddr[peer][P.PA_BITS-1:GRANULE_BITS]))
              else $fatal(1, "Two local M stores to one physical word");
        end
    end
  end
endmodule
