// aesTB.sv
// Max De Somma
// mdesomma@g.hmc.edu
// 10/27/2024

module coreTB();
logic clk, load, done;
logic [127:0] key, plaintext, cyphertext;

aes_core dut(.clk(clk), .load(load), .key(key), .plaintext (plaintext), .done(done), .cyphertext (cyphertext));

always
   begin
     clk = 1; #5;
     clk = 0; #5;
   end

initial
 begin
	load = 1;
	#7
	load = 0;
	key = 128'h2b7e151628aed2a6abf7158809cf4f3c;
	plaintext = 128'h3243f6a8885a308d313198a2e0370734;
	#50;
 end

endmodule

module shiftRowsTB();
logic [127:0] a;
logic [127:0] y;

shiftRows dut(.a(a), .y(y));

initial
 begin
	a = 128'hd42711aee0bf98f1b8b45de51e415230;
	#50;
 end


endmodule

module subByteTB();
logic [127:0] a;
logic clk;
logic [127:0] y;

subByte dut(.a(a), .clk(clk), .y(y));

 // Generate clock signal with a period of 10 timesteps.
 always
   begin
     clk = 1; #5;
     clk = 0; #5;
   end

initial
 begin
	a = 128'h193de3bea0f4e22b9ac68d2ae9f84808;
	#50;
 end

endmodule

module keyExpansionTB();
	logic clk;
	logic [127:0] currentWords, nextWords;
	logic [31:0] rcon;

	generateNextWords dut(.clk(clk), .currentWords(currentWords), .rcon(rcon), .nextWords(nextWords));

	always
   	 begin
     		clk = 1; #5;
     		clk = 0; #5;
	 end
	
	initial
	 begin
	  currentWords = 128'h2b7e151628aed2a6abf7158809cf4f3c;
	  rcon = 31'h01000000;
	 end
   	
endmodule

module oneWordTB();
	logic clk;
	logic [31:0] temp, rcon, wordFourBefore, word;

	oneWord dut(.clk(clk), .temp(temp), .rcon(rcon), .wordFourBefore(wordFourBefore), .word(word));
	always
   	 begin
     		clk = 1; #5;
     		clk = 0; #5;
	 end
	
	initial
	 begin
	  temp = 32'ha0fafe17;
	  rcon = 32'h01000000;
	  wordFourBefore = 32'h28aed2a6;
	 end
endmodule
