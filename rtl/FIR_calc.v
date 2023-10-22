`timescale 1ns / 100ps
module FIR_calc(    input clk,
                    input rstn,
					input [31:0] X,
                    input [31:0] tap,
                    output reg [31:0] Y,
                    output done
                    );
					
reg [3:0] done_cnt;

// 11 cycle counter
always @(posedge clk or negedge rstn) begin
    if (~rstn) 
		begin
			done_cnt <= 4'd1;
			Y <= 68'd0;
		end 
	else begin
        if (done) 
			begin
				Y <= (X * tap);
				done_cnt <= 4'd1;
			end 
		else 
			begin
				Y <= Y + (X * tap);
				done_cnt <= done_cnt+1;
			end
    end
end

assign done = (done_cnt == 4'b1011)? (1):(0) ;

endmodule