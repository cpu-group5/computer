`include "common.vh"

module register_file #(
	parameter FPR = "hoge"
) (
	input logic clk,
	inst_if inst,
	output cdb_t arch_read[2],
	input logic issue,
	input logic[ROB_WIDTH-1:0] issue_tag,
	input logic commit,
	input logic[REG_WIDTH-1:0] commit_arch_num,
	input logic[ROB_WIDTH-1:0] commit_tag,
	input logic[31:0] commit_data,
	input logic reset,
	req_if acc_req[N_ACC],
	input logic[31:0] acc_data[N_ACC],
	output logic acc_all_valid_parallel,
	output logic no_acc_req
);
	localparam LATENCY_FADD = 6;
	localparam cdb_t register_init = '{
		valid: 1,
		tag: {ROB_WIDTH{1'bx}},
		data: 0
	};
	cdb_t registers[2**REG_WIDTH] = '{default: register_init};
	logic[$clog2(LATENCY_FADD):0] fadd_count[N_ACC] = '{default: 0};
	logic[31:0] fadd_result[N_ACC];

	assign arch_read[0] = registers[inst.r1];
	assign arch_read[1] = registers[inst.r2];

	for (genvar i=0; i<2**REG_WIDTH; i++) begin
		always_ff @(posedge clk) begin
			if (reset) begin
				registers[i].valid <= 1;
			end else if (issue && i==inst.r0) begin
				registers[i].valid <= 0;
			end else if (commit && /* !registers[i].valid && */ registers[i].tag==commit_tag) begin
				registers[i].valid <= 1;
			end

			if (issue && i==inst.r0) begin
				registers[i].tag <= issue_tag;
			end

			if (FPR && i>=2**REG_WIDTH-N_ACC && fadd_count[i-(2**REG_WIDTH-N_ACC)][0]) begin
				registers[i].data <= fadd_result[i-(2**REG_WIDTH-N_ACC)];
			end else if (commit && !registers[i].valid && i==commit_arch_num) begin
				registers[i].data <= commit_data;
			end
		end
	end

	generate
		if (FPR) begin
			assign acc_all_valid_parallel = fadd_count[0]<=1 && fadd_count[1]<=1 && fadd_count[2]<=1;
			assign no_acc_req = !acc_req[0].valid && !acc_req[1].valid && !acc_req[2].valid;
			for (genvar i=0; i<N_ACC; i++) begin
				assign acc_req[i].ready = fadd_count[i]<=1;
				always_ff @(posedge clk) begin
					fadd_count[i] <= acc_req[i].valid&&acc_req[i].ready ? LATENCY_FADD : fadd_count[i]==0 ? 0 : fadd_count[i]-1;
				end
				fadd_core fadd_core(
					.aclk(clk),
					.s_axis_a_tdata(fadd_count[i][0] ? fadd_result[i] : registers[2**REG_WIDTH-N_ACC+i].data),  //バイパス
					.s_axis_b_tdata(acc_data[i]),
					.m_axis_result_tdata(fadd_result[i])
				);
			end
		end
	endgenerate
endmodule
