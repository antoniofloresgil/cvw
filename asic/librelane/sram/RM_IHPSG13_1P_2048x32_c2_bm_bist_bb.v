// Black box of the IHP SRAM macro for synthesis (ports copied from the PDK model)
(* blackbox *)
module RM_IHPSG13_1P_2048x32_c2_bm_bist (
    A_CLK,
    A_MEN,
    A_WEN,
    A_REN,
    A_ADDR,
    A_DIN,
    A_DLY,
    A_DOUT,
    A_BM,
    A_BIST_CLK,
    A_BIST_EN,
    A_BIST_MEN,
    A_BIST_WEN,
    A_BIST_REN,
    A_BIST_ADDR,
    A_BIST_DIN,
    A_BIST_BM
);

    input A_CLK;
    input A_MEN;
    input A_WEN;
    input A_REN;
    input [10:0] A_ADDR;
    input [31:0] A_DIN;
    input A_DLY;
    output [31:0] A_DOUT;
    input [31:0] A_BM;
    input A_BIST_CLK;
    input A_BIST_EN;
    input A_BIST_MEN;
    input A_BIST_WEN;
    input A_BIST_REN;
    input [10:0] A_BIST_ADDR;
    input [31:0] A_BIST_DIN;
    input [31:0] A_BIST_BM;
endmodule
