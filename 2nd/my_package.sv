package my_package;
	parameter IN_BUFFER_WIDTH = 9;  //4バイト単位
	parameter OUT_BUFFER_WIDTH = 9;  //1バイト単位
	parameter INST_WIDTH = 32;
	parameter INST_MEM_WIDTH = 14;
	parameter REG_WIDTH = 5;
	parameter ROB_WIDTH = 4;
	parameter COMMIT_RING_WIDTH = 4;  // ROB_WIDTH >= COMMIT_RING_WIDTH

	typedef struct {  //packedでないとfunctionの引数にできない? -> packageの中に入れたらエラーが出なくなった
		logic valid;
		logic[ROB_WIDTH-1:0] tag;
		logic[31:0] data;
	} cdb_t;

	function logic tag_match(cdb_t cdb, logic[ROB_WIDTH-1:0] tag);
		return cdb.valid && cdb.tag==tag;
	endfunction

	typedef struct {  //packedでないと "arrays have different elements" というエラーが出る -> packageの中に入れたらエラーが出なくなった
		logic valid;
		logic[31:0] data;
	} rob_entry;

	typedef enum logic[2:0] {
		 COMMIT_GPR,
		 COMMIT_FPR,
		 COMMIT_GPR_IN,
		 COMMIT_FPR_IN,
		 COMMIT_SW,
		 COMMIT_OUT,
		 COMMIT_B,
		 COMMIT_X = 3'bx
	} commit_ring_entry;
endpackage