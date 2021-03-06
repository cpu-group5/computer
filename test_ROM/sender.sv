module sender #(
	parameter SENDER_PERIOD = "hoge"
) (
	input logic clk,
	input logic[7:0] in,
	input logic valid,
	output logic out,
	output logic ready
);
	logic[7:0] buffer;
	logic[$clog2(SENDER_PERIOD-1):0] count_period = 0;
	logic sending = 1'b0;
	logic[2:0] state = 3'b001;  /* 100->sending->101 */

	assign ready = !(sending || state[2]);

	always_comb begin
		if (sending) begin
			out <= buffer[state];
		end else begin
			out <= state[0];
		end
	end

	always @(posedge clk) begin
		if (valid && ready) begin
			state <= 3'b100;
			buffer <= in;
		end

		if (count_period == SENDER_PERIOD-1) begin
			count_period <= 0;
			if (sending) begin
				if (state == 3'b111) begin
					sending <= 1'b0;
					state <= 3'b101;
				end else begin
					state <= state + 1;
				end
			end else begin
				if (state[0] == 1'b0) begin
					sending <= 1;
					state <= 3'b000;
				end else begin
					state[2] <= 1'b0;
				end
			end
		end else begin
			if (!ready) begin
				count_period <= count_period + 1;
			end
		end
	end
endmodule
