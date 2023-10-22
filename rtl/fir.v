`include "bram11.v"
`include "FIR_calc.v"
`timescale 1ns / 100ps
module fir 
#(  parameter pADDR_WIDTH = 12,
    parameter pDATA_WIDTH = 32,
    parameter Tape_Num    = 11,
    parameter IDLE        =  0,
    parameter WAIT        =  0,
    parameter TRANS       =  1,
    parameter Receive     =  1,
    parameter WORK        =  2
)
(
    // write chennel
    output  reg                     awready,
    output  reg                     wready,
	input   wire                    awvalid,
	input   wire [(pADDR_WIDTH-1):0] awaddr,
    input   wire                    wvalid,
    input   wire [(pDATA_WIDTH-1):0] wdata,
    
    // read chennel
    output  reg                     arready,
    input   wire                    rready,
	input   wire                    arvalid,
	input   wire [(pADDR_WIDTH-1):0] araddr,
    output  reg                     rvalid,
    output  reg [(pDATA_WIDTH-1):0] rdata,

    // ss slave // sm master
    input   wire                     ss_tvalid, 
    input   wire [(pDATA_WIDTH-1):0] ss_tdata, 
    input   wire                     ss_tlast,  
    output  reg                      ss_tready,

    input   wire                    sm_tready,
    output  reg                     sm_tvalid,
    output  reg [(pDATA_WIDTH-1):0] sm_tdata, 
    output  reg                     sm_tlast, 
    
    // bram for tap RAM
    output  reg [3:0]               tap_WE,
    output  reg                     tap_EN,
    output  reg [(pDATA_WIDTH-1):0] tap_Di,
    output  reg [(pADDR_WIDTH-1):0] tap_A,
    input   wire [(pDATA_WIDTH-1):0] tap_Do,

    // bram for data RAM
    output  reg [3:0]               data_WE,
    output  reg                     data_EN,
    output  reg [(pDATA_WIDTH-1):0] data_Di,
    output  reg [(pADDR_WIDTH-1):0] data_A,
    input   wire [(pDATA_WIDTH-1):0] data_Do,

    input   wire                     axis_clk,
    input   wire                     axis_rst_n
);

    // parameters //
    reg [2:0] FIR_STATE ; // IDEL // D // WORK
    integer next_FIR_STATE ;
    
    reg ap_start , ap_idle , ap_done;
    reg [1:0] araddr_map;
    reg [3:0] tap_cnt , data_cnt ;
    reg AW_STATE ;
    integer next_AW_STATE ;
    reg AR_STATE ;
    integer next_AR_STATE ;
    reg [1:0] awaddr_map;
    reg [31:0] data_length ;
    reg [1:0] tap_RW ; // 10 : Write // 01 : Read // 00 : IDLE
    // parameters //

    // initial ap signals //
    initial begin
        ap_done = 0;
        ap_start = 0;
    end
    // initial ap signals //

    //////// ap_idle ////////
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n) begin
            ap_idle <= 1'b1 ;
			data_length <= 32'd0 ; //reset length
        end else begin
            if (ap_start) 
                ap_idle <= 1'b0 ;
            else if (FIR_STATE==IDLE) 
                ap_idle <= 1'b1 ;
            else 
                ap_idle <= ap_idle;
        end
    end
    //////// ap_idle ////////


    ///////// RAM pointer ////////
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n)
			begin
				tap_cnt <= 0 ;
				data_cnt <= 0 ;
			end 
		else begin
			if (tap_EN) begin
				if (tap_cnt==4'd10) 
					tap_cnt <= 4'b0000;
				else 
					tap_cnt <= tap_cnt + 1'b1 ;
            end
            
            if (data_EN) begin
                if (tap_cnt == 4'd10) begin
                    data_cnt <= data_cnt ; 
                    data_EN <= 1'b1 ;
                end 
				else if (data_cnt == 4'd10) begin
                    data_cnt <= 4'b0000;
                    data_EN <= 1'b0 ; 
                end 
				else begin
                    data_cnt <= data_cnt + 1'b1 ;
                    data_EN <= 1'b0 ; 
                end
            end
        end
    end

    always @(*) begin
        tap_A = tap_cnt << 2 ;
        data_A = data_cnt << 2 ;
    end
    //////// RAM pointer /////////
	
	//////// tap_RW controller ////////
    // tap_RW // 10 : Write | 01 : Read | 00 : IDLE
    always @(*) begin
        if (tap_RW[1]) begin  // Write
            tap_EN = 1'b1;
            tap_WE = 4'b1111 ;
        end else if (tap_RW[0]) begin  // Read
            tap_EN = 1'b1;
            tap_WE = 4'd0;
        end else begin
            tap_EN = 1'b0;
            tap_WE = 4'd0;
        end
    end

    always @(*) begin
        if (FIR_STATE == IDLE) begin
            if (awaddr_map == 2'd2 && araddr_map == 2'd2) begin
				if(wvalid && wready)
					tap_RW = 2'b10;
				else if(rvalid && rready)
					tap_RW = 2'b01;
                else
					tap_RW = 2'b00;
            end else if (awaddr_map == 2'd2 && araddr_map != 2'd2) begin
				if(wvalid & wready)
					tap_RW = 2'b10;
				else
					tap_RW = 2'b00;
            end else if (araddr_map == 2'd2 && awaddr_map != 2'd2) begin
				if(rvalid & rready)
					tap_RW = 2'b01;
				else
					tap_RW = 2'b00;
            end else
                tap_RW = 2'b00;
        end else if (FIR_STATE == WORK)
            tap_RW = 2'b01;
        else
            tap_RW = 2'b00;
    end
    //////// tap_RW controller /////////
    
    //////// FIR_FSM ////////
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n) begin
            FIR_STATE <= IDLE ;
			AW_STATE <= WAIT ;
			AR_STATE <= WAIT ;
        end else begin
            FIR_STATE <= next_FIR_STATE ;
			AW_STATE <= next_AW_STATE ;
			AR_STATE <= next_AR_STATE ;
        end
    end

    always @(*) begin
        case (FIR_STATE)
            IDLE: begin
			if(ap_start)
                next_FIR_STATE = WORK;
            end 
            WORK : begin
				if(ap_done && rready && rvalid && arvalid)
					next_FIR_STATE = IDLE;
				else
					next_FIR_STATE = WORK;
            end
            default: begin 
                next_FIR_STATE = IDLE ;
                // $display("default nextstate");
            end
        endcase
    end
    //////// FIR_FSM ////////

    //////// axilite W FSM ////////
    always @(*) begin
        if (FIR_STATE==IDLE) begin
            case (AW_STATE)
                WAIT : begin
					if(awvalid)
						next_AW_STATE = Receive;
					else
						next_AW_STATE = WAIT;
                    awready = 1'b1 ;
                    wready  = 1'b0 ;
                end
                Receive : begin
					if(wvalid)
						next_AW_STATE = WAIT;
					else
						next_AW_STATE = Receive;
                    awready = 1'b0 ;
                    wready  = 1'b1 ;
                end  
                default: begin
                    next_AW_STATE = WAIT ;
                    awready = 1'b1 ;
                    wready  = 1'b0 ;
                end
            endcase
        end else 
            next_AW_STATE = WAIT ;
    end
    //////// axilite W FSM ////////

    //////// axilite R FSM ////////
    always @(*) begin
        case (AR_STATE)
            WAIT : begin
				if(arvalid)
					next_AR_STATE = TRANS;
				else
					next_AR_STATE = WAIT;
                arready = 1'b1;
                rvalid = 1'b0;
            end
            TRANS : begin
				if(rready)
					next_AR_STATE = WAIT;
				else
					next_AR_STATE = TRANS;
                arready = 1'b0;
                rvalid = 1'b1;
                case (araddr_map)
                    2'd0 : rdata = {{29{1'b0}}, ap_idle, ap_done, ap_start};
                    2'd1 : rdata = data_length;
                    2'd2 : rdata = tap_Do;  
                    default: rdata = {{29{1'b0}}, ap_idle, ap_done, ap_start};
                endcase
            end
            default: begin
                next_AR_STATE = WAIT;
                arready = 1'b1;
                rvalid = 1'b0;
            end
        endcase
    end
    //////// axilite R FSM ////////

    //////// awaddr decode ////////
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n) begin
            awaddr_map <= 2'd3; 
        end else begin
            if (awvalid && awready) begin
                if (awaddr == 12'h00) begin // ap_start
                    awaddr_map <= 2'd0;
                end
                else if (awaddr > 12'h0F && awaddr < 12'h15) begin
                    awaddr_map <= 2'd1;
                end 
                else if (awaddr > 12'h1F && awaddr < 12'h100) begin
                    awaddr_map <= 2'd2;
                end else begin
                    awaddr_map <= 2'd3;
                end
            end
        end
    end
    //////// awaddr decode ////////

    //////// araddr decode ////////
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n ) begin
            araddr_map <= 2'd3; // none
        end else begin
            if (arvalid && arready) begin
                if (awaddr == 12'h00) begin
                    araddr_map <= 2'd0 ;
                end
                else if (awaddr > 12'h0F && awaddr < 12'h15) begin
                    araddr_map <= 2'd1; //length
                end 
                else if (awaddr > 12'h1F && awaddr < 12'h100) begin
                    araddr_map <= 2'd2; //read tap
                end else begin
                    araddr_map <= 2'd3; //none
                end
            end
        end
    end
    //////// araddr decode ////////

    // tap ram 
    always @(*) begin
        if (FIR_STATE == IDLE && wready && wvalid) begin
			case (awaddr_map)
				2'd0 : begin // 0x00 //ap_start
					if(wdata[0]==1'd1) begin
						ap_start = 1 ;
						$display("----- FIR calc -----");
					end else
						ap_start = 0 ;
				end
				2'd1 : data_length = wdata ; // 0x10-14
				2'd2 : tap_Di = wdata ; // 0x20-FF
			endcase
        end else if(ap_start && ss_tvalid && ss_tready) // FIR_STATE == WORK
			ap_start = 0;
		else
			ap_start = ap_start;
    end
    // store data (W)//

    // AXI-Stream //
    reg rstn_fir ;
    wire done_fir ;
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n) begin
            data_WE <= 4'd0;
            data_EN <= 1'b0 ;
            ss_tready <= 1'b0 ;
            rstn_fir <= 1'b0 ; 
        end else begin
            if (ap_start) begin
                data_WE <= 4'b1111 ;
                data_EN <= 1'b1 ;
                data_cnt <= 4'd10;
                ss_tready <= 1'b1 ;
                data_Di <= ss_tdata ;
                rstn_fir <= 1'b0 ; 
            end else if ((FIR_STATE==WORK)) begin // steadily receive data
                data_EN <= 1'b1 ;
                rstn_fir <= 1'b1 ; 
                if (ss_tready && ss_tvalid)
                    data_Di <= ss_tdata ;
				case(tap_cnt)
					4'd09 : begin
						ss_tready <= 1'b1;
						data_WE <= 4'd0000;
					end
					4'd10 : begin
						ss_tready <= 1'b0;
						data_WE <= 4'b1111;
					end
					default : begin 
						ss_tready <= 1'b0;
						data_WE <= 4'd0000;
					end	
				endcase
            end else if (ap_done) begin
                data_EN <= 1'b0 ;
                ss_tready <= 1'b0 ;
                rstn_fir <= 1'b0 ; 
            end else begin
                ss_tready <= 1'b0 ;
                rstn_fir <= 1'b0 ; 
                data_EN <= 1'b0 ;
            end
        end
    end
	
    //////// FIR_calc //////
    wire [31:0] Y ;
    reg [31:0] Y_reg ;
    FIR_calc FIR_kernel(    .clk(axis_clk),
							.rstn(rstn_fir),
							.X(data_Do),
                            .tap(tap_Do),
                            .Y(Y),
                            .done(done_fir)); 
    
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n) 
            Y_reg <= 32'd0;
        else if(done_fir == 1)
            Y_reg <= Y;
		else
			Y_reg <= Y_reg;
    end
    //////// FIR_calc //////	

    // axi stream sm 
    // output  wire                     sm_tvalid, 
    // output  wire [(pDATA_WIDTH-1):0] sm_tdata, 
    // output  wire                     sm_tlast, 
    reg [1:0] Last ;
    initial begin
        Last = 2'b00 ;
    end
    always @(posedge axis_clk or negedge axis_rst_n) begin
        if (~axis_rst_n) begin
            sm_tdata <= 32'd0;
            sm_tlast <= 1'd0;
            sm_tvalid <= 1'd0;
        end else begin
            if (ss_tlast && FIR_STATE==WORK)
                Last <= 2'b01;
            if (done_fir) begin     // sm_tvalid set
                if (Last==2'b01) begin // last Y 
                    Last <= 2'b10;
                    sm_tdata <= Y;
                    sm_tvalid <= 1'd1;
                    sm_tlast <= 1'd0;
                end else if (Last==2'b10) begin
                    Last <= 2'b00;
                    sm_tdata <= Y;
                    sm_tvalid <= 1'd1;
                    sm_tlast <= 1'd1;
                end else begin      
                    sm_tdata <= Y ;
                    sm_tvalid <= 1'd1;
                end
			end else if (sm_tready && sm_tvalid) begin    // sm_tvalid reset
                sm_tvalid <= 1'b0;
                sm_tlast <= 1'd0;
            end else begin 
                sm_tvalid <= 1'b0;
                sm_tlast <= 1'd0;
            end

            if (sm_tlast && sm_tready && sm_tvalid) 
                ap_done <= 1; 
            else if (araddr_map==2'b0 && rready && rvalid && arvalid) 
                ap_done <= 0;
            else 
                ap_done <= ap_done;
        end
    end

endmodule

