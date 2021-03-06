`include "common.vh"

localparam N_BACKUP_ENTRY = 4;
typedef enum logic[1:0] {
	CMP_FZ,
	CMP_FLE,
	CMP_E,
	CMP_LE
} cmp_type_t;
typedef struct {
	cmp_type_t cmp_type;
	cdb_t opd[2];
} cmp_entry;
typedef struct {
	logic failure;
	logic[1:0] prediction;
	logic[PATTERN_WIDTH-1:0] pattern;
	logic[INST_MEM_WIDTH-1:0] addr_on_failure;
	logic[ADDR_STACK_WIDTH-1:0] stack_pointer;
	logic[ROB_WIDTH-1:0] gpr_pointer;
	logic[ROB_WIDTH-1:0] fpr_pointer;
} b_entry;
typedef struct {
	logic[$clog2(N_B_ENTRY-1):0] pointer;  //b_entryへのポインタ  //b_entryにカウンタを持たせる実装の方が良いかも
	logic[ADDR_STACK_WIDTH-1:0] stack_pointer;
	logic[INST_MEM_WIDTH-1:0] addr;
} backup_entry;

module b #(
) (
	input logic clk,
	inst_if inst,
	input cdb_t gpr_read[2],
	input cdb_t fpr_read[2],
	input cdb_t gpr_cdb,
	input cdb_t fpr_cdb,
	req_if issue_req_b,
	req_if issue_req_jal,
	req_if issue_req_fork,
	req_if issue_req_end_parent,
	input logic[ROB_WIDTH-1:0] gpr_issue_tag,
	input logic[ROB_WIDTH-1:0] fpr_issue_tag,
	input logic[ROB_WIDTH-1:0] gpr_commit_tag,
	input logic[ROB_WIDTH-1:0] fpr_commit_tag,
	output logic speculating,
	output logic sync_b_gpr,
	output logic sync_b_fpr,
	output logic commit,
	input logic[1:0] prediction_begin,
	input logic[PATTERN_WIDTH-1:0] pattern_begin,
	input logic[INST_MEM_WIDTH-1:0] addr_on_failure_in,
	output logic[$clog2(N_B_ENTRY):0] b_count_next,
	output logic failure,
	output logic[1:0] prediction_end,
	output logic[PATTERN_WIDTH-1:0] pattern_end,
	output logic[INST_MEM_WIDTH-1:0] addr_on_failure_out,
	input logic reset,
	input logic[INST_MEM_WIDTH-1:0] pc,
	output logic[INST_MEM_WIDTH-1:0] return_addr
);
	logic[$clog2(N_B_ENTRY):0] cmp_count = 0;
	logic[$clog2(N_B_ENTRY):0] b_count = 0;
	logic[$clog2(N_BACKUP_ENTRY):0] backup_count = 0;
	cmp_entry cmp_e[N_B_ENTRY];
	cmp_entry cmp_e_updated[N_B_ENTRY];
	cmp_entry cmp_e_new;
	b_entry b_e[N_B_ENTRY];
	b_entry b_e_moved[N_B_ENTRY];
	b_entry b_e_new;
	backup_entry backup_e[N_BACKUP_ENTRY];
	backup_entry backup_e_updated[N_BACKUP_ENTRY];
	backup_entry backup_e_new;
	logic[INST_MEM_WIDTH-1:0] addr_stack[2**ADDR_STACK_WIDTH];
	logic[INST_MEM_WIDTH-1:0] addr_stack_next[2**ADDR_STACK_WIDTH];
	logic[ADDR_STACK_WIDTH-1:0] stack_pointer = 2**ADDR_STACK_WIDTH-1;  //スタックのトップ(戻り番地がある位置)を指す (スタックのトップの1つ上を指すという実装も考えられる?)
	logic[ADDR_STACK_WIDTH-1:0] stack_pointer_next;
	for (genvar i=0; i<N_B_ENTRY; i++) begin
		initial begin
			b_e[i].failure <= 0;
		end
	end

	//cmp
	assign cmp_e_new.cmp_type = inst.op[4] ? inst.op[3] ? CMP_LE : CMP_E
	                                       : inst.op[2] ? CMP_FLE : CMP_FZ;
	cdb_t read[2];
	assign read = cmp_e_new.cmp_type==CMP_E || cmp_e_new.cmp_type==CMP_LE ? gpr_read : fpr_read;
	assign cmp_e_new.opd[0].valid = read[0].valid;
	assign cmp_e_new.opd[0].tag   = read[0].tag;
	assign cmp_e_new.opd[0].data  = read[0].data;
	assign cmp_e_new.opd[1].valid = (cmp_e_new.cmp_type==CMP_E || cmp_e_new.cmp_type==CMP_LE) && inst.op[2] || read[1].valid;
	assign cmp_e_new.opd[1].tag   = read[1].tag;
	assign cmp_e_new.opd[1].data  = (cmp_e_new.cmp_type==CMP_E || cmp_e_new.cmp_type==CMP_LE) && inst.op[2] ? 32'($signed(inst.c_cmp)) : read[1].data;
	for (genvar i=0; i<N_B_ENTRY; i++) begin
		assign cmp_e_updated[i].cmp_type = cmp_e[i].cmp_type;
		cdb_t cdb;
		assign cdb = cmp_e_updated[i].cmp_type==CMP_E || cmp_e_updated[i].cmp_type==CMP_LE ? gpr_cdb : fpr_cdb;
		for (genvar j=0; j<2; j++) begin
			assign cmp_e_updated[i].opd[j].valid = cmp_e[i].opd[j].valid || tag_match(cdb, cmp_e[i].opd[j].tag);
			assign cmp_e_updated[i].opd[j].tag   = cmp_e[i].opd[j].tag;
			assign cmp_e_updated[i].opd[j].data  = cmp_e[i].opd[j].valid ? cmp_e[i].opd[j].data : cdb.data;
		end
	end

	wire dispatch = !b_e[0].failure &&
	                !b_e[1].failure &&
	                !b_e[2].failure &&
	                cmp_count!=0 && cmp_e[0].opd[0].valid && (cmp_e[0].cmp_type==CMP_FZ || cmp_e[0].opd[1].valid);
	wire[$clog2(N_B_ENTRY)-1:0] dispatch_to = b_count - cmp_count;
	logic[7:0] fcmple_out;
	fcmple_core fcmple_core(
		.s_axis_a_tdata(cmp_e[0].opd[0].data),
		.s_axis_b_tdata(cmp_e[0].opd[1].data),
		.m_axis_result_tdata(fcmple_out)
	);
	wire cmp_result = cmp_e[0].cmp_type==CMP_E   ? cmp_e[0].opd[0].data == cmp_e[0].opd[1].data :
	                  cmp_e[0].cmp_type==CMP_LE  ? $signed(cmp_e[0].opd[0].data) <= $signed(cmp_e[0].opd[1].data) :
	                  cmp_e[0].cmp_type==CMP_FLE ? fcmple_out[0] :
	                  cmp_e[0].cmp_type==CMP_FZ  ? cmp_e[0].opd[0].data[30:23]==0 : 1'bx;

	always_ff @(posedge clk) begin
		cmp_count <= reset ? 0 : cmp_count - dispatch + b_issue;
		if (dispatch) begin
			cmp_e[0] <= cmp_count>=2 ? cmp_e_updated[1] : cmp_e_new;
			cmp_e[1] <= cmp_count>=3 ? cmp_e_updated[2] : cmp_e_new;
			cmp_e[2] <= cmp_count>=4 ? cmp_e_updated[3] : cmp_e_new;
			cmp_e[3] <= cmp_e_new;
		end else begin
			cmp_e[0] <= cmp_count>=1 ? cmp_e_updated[0] : cmp_e_new;
			cmp_e[1] <= cmp_count>=2 ? cmp_e_updated[1] : cmp_e_new;
			cmp_e[2] <= cmp_count>=3 ? cmp_e_updated[2] : cmp_e_new;
			cmp_e[3] <= cmp_count>=4 ? cmp_e_updated[3] : cmp_e_new;
		end
	end

	//general
	assign speculating = b_count!=0;
	assign sync_b_gpr = b_e[0].gpr_pointer==gpr_commit_tag;
	assign sync_b_fpr = b_e[0].fpr_pointer==fpr_commit_tag;
	assign commit = cmp_count!=b_count && sync_b_gpr && sync_b_fpr;
	assign issue_req_b.ready = commit || b_count < N_B_ENTRY;
	wire b_issue = issue_req_b.valid && issue_req_b.ready;

	//b
	assign b_e_new.failure         = 0;
	assign b_e_new.prediction      = prediction_begin;
	assign b_e_new.pattern         = pattern_begin;
	assign b_e_new.addr_on_failure = addr_on_failure_in;
	assign b_e_new.stack_pointer   = stack_pointer;
	assign b_e_new.gpr_pointer     = gpr_issue_tag;
	assign b_e_new.fpr_pointer     = fpr_issue_tag;
	always_comb begin
		if (commit) begin
			b_e_moved[0] <= b_count>=2 ? b_e[1] : b_e_new;
			b_e_moved[1] <= b_count>=3 ? b_e[2] : b_e_new;
			b_e_moved[2] <= b_count>=4 ? b_e[3] : b_e_new;
			b_e_moved[3] <= b_e_new;
		end else begin
			b_e_moved[0] <= b_count>=1 ? b_e[0] : b_e_new;
			b_e_moved[1] <= b_count>=2 ? b_e[1] : b_e_new;
			b_e_moved[2] <= b_count>=3 ? b_e[2] : b_e_new;
			b_e_moved[3] <= b_count>=4 ? b_e[3] : b_e_new;
		end
	end
	assign b_count_next = b_count - commit;  //resetもissueもされない場合の、b_countの次の値
	always_ff @(posedge clk) begin
		b_count <= reset ? 0 : b_count - commit + b_issue;
	end
	for (genvar i=0; i<N_B_ENTRY; i++) begin
		always_ff @(posedge clk) begin
			b_e[i].failure         <= b_e_moved[i].failure || (dispatch && dispatch_to-commit==i && cmp_result!=b_e_moved[i].prediction[1]);
			b_e[i].prediction      <= b_e_moved[i].prediction;
			b_e[i].pattern         <= b_e_moved[i].pattern;
			b_e[i].addr_on_failure <= b_e_moved[i].addr_on_failure;
			b_e[i].stack_pointer   <= b_e_moved[i].stack_pointer;
			b_e[i].gpr_pointer     <= b_e_moved[i].gpr_pointer;
			b_e[i].fpr_pointer     <= b_e_moved[i].fpr_pointer;
		end
	end

	assign failure             = b_e[0].failure;
	assign prediction_end      = b_e[0].prediction;
	assign pattern_end         = b_e[0].pattern;
	assign addr_on_failure_out = b_e[0].addr_on_failure;

	//backup
	assign backup_e_new.pointer       = b_count - commit;
	assign backup_e_new.stack_pointer = stack_pointer+1;
	assign backup_e_new.addr          = addr_stack[backup_e_new.stack_pointer];
	for (genvar i=0; i<N_BACKUP_ENTRY; i++) begin
		assign backup_e_updated[i].pointer       = backup_e[i].pointer - commit;
		assign backup_e_updated[i].stack_pointer = backup_e[i].stack_pointer;
		assign backup_e_updated[i].addr          = backup_e[i].addr;
	end

	assign issue_req_jal.ready = backup_count < N_BACKUP_ENTRY || commit&&backup_e[0].pointer==1;
	wire stack_push = issue_req_jal.valid&&issue_req_jal.ready || issue_req_fork.valid&&issue_req_fork.ready;
	wire stack_pop = inst.is_jr || issue_req_end_parent.valid&&issue_req_end_parent.ready;

	logic shift[4];
	assign shift[0] = backup_e[0].pointer!=1;
	assign shift[1] = backup_e[0].pointer==1 && backup_e[1].pointer!=1;
	assign shift[2] = backup_e[0].pointer==1 && backup_e[1].pointer==1 && backup_e[2].pointer!=1;
	assign shift[3] = backup_e[0].pointer==1 && backup_e[1].pointer==1 && backup_e[2].pointer==1 && backup_e[3].pointer!=1;
	always_ff @(posedge clk) begin
		backup_count <= reset ? 0 :
		                (!commit ? backup_count :
		                 backup_count>=4&&shift[0] ? 4 :
		                 backup_count>=4&&shift[1] ||
		                 backup_count==3&&shift[0] ? 3 :
		                 backup_count>=4&&shift[2] ||
		                 backup_count==3&&shift[1] ||
		                 backup_count==2&&shift[0] ? 2 :
		                 backup_count>=4&&shift[3] ||
		                 backup_count==3&&shift[2] ||
		                 backup_count==2&&shift[1] ||
		                 backup_count==1&&shift[0] ? 1 : 0) + (stack_push && b_count-commit!=0);
		if (commit) begin
			backup_e[0] <= backup_count>=4 && shift[3] ? backup_e_updated[3] :
			               backup_count>=3 && shift[2] ? backup_e_updated[2] :
			               backup_count>=2 && shift[1] ? backup_e_updated[1] :
			               backup_count>=1 && shift[0] ? backup_e_updated[0] : backup_e_new;
			backup_e[1] <= backup_count>=4 && shift[2] ? backup_e_updated[3] :
			               backup_count>=3 && shift[1] ? backup_e_updated[2] :
			               backup_count>=2 && shift[0] ? backup_e_updated[1] : backup_e_new;
			backup_e[2] <= backup_count>=4 && shift[1] ? backup_e_updated[3] :
			               backup_count>=3 && shift[0] ? backup_e_updated[2] : backup_e_new;
			backup_e[3] <= backup_count>=4 && shift[0] ? backup_e_updated[3] : backup_e_new;
		end else begin
			backup_e[0] <= backup_count>=1 ? backup_e_updated[0] : backup_e_new;
			backup_e[1] <= backup_count>=2 ? backup_e_updated[1] : backup_e_new;
			backup_e[2] <= backup_count>=3 ? backup_e_updated[2] : backup_e_new;
			backup_e[3] <= backup_count>=4 ? backup_e_updated[3] : backup_e_new;
		end
	end

	//addr_stack
	always_comb begin
		stack_pointer_next <= reset ? b_e[0].stack_pointer :
		                      stack_push ? stack_pointer+1 :
		                      stack_pop  ? stack_pointer-1 : stack_pointer;
	end
	always_ff @(posedge clk) begin
		stack_pointer <= stack_pointer_next;
	end
	for (genvar i=0; i<2**ADDR_STACK_WIDTH; i++) begin
		always_comb begin
			if (reset) begin
				addr_stack_next[i] <= backup_count>=1 && backup_e[0].stack_pointer==i ? backup_e[0].addr :
				                      backup_count>=2 && backup_e[1].stack_pointer==i ? backup_e[1].addr :
				                      backup_count>=3 && backup_e[2].stack_pointer==i ? backup_e[2].addr :
				                      backup_count>=4 && backup_e[3].stack_pointer==i ? backup_e[3].addr : addr_stack[i];
			end else if (stack_push && ADDR_STACK_WIDTH'(stack_pointer+1)==i) begin
				addr_stack_next[i] <= pc;
			end else begin
				addr_stack_next[i] <= addr_stack[i];
			end
		end
		always_ff @(posedge clk) begin
			addr_stack[i] <= addr_stack_next[i];
		end
	end

	always_ff @(posedge clk) begin
		return_addr <= addr_stack_next[stack_pointer_next];
	end
endmodule
