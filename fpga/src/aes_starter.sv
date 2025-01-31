// aesTB.sv
// Max De Somma
// mdesomma@g.hmc.edu
// 10/27/2024

/////////////////////////////////////////////
// aes
//   Top level module with SPI interface and SPI core
/////////////////////////////////////////////

module aes(//input  logic clk,
           input  logic sck, 
           input  logic sdi,
           output logic sdo,
           input  logic load,
           output logic done);
                    
    logic [127:0] key, plaintext, cyphertext;
    HSOSC hf_osc (.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(int_osc));        
    aes_spi spi(sck, sdi, sdo, done, key, plaintext, cyphertext);   
    aes_core core(int_osc, load, key, plaintext, done, cyphertext);
endmodule

/////////////////////////////////////////////
// aes_spi
//   SPI interface.  Shifts in key and plaintext
//   Captures ciphertext when done, then shifts it out
//   Tricky cases to properly change sdo on negedge clk
/////////////////////////////////////////////

module aes_spi(input  logic sck, 
               input  logic sdi,
               output logic sdo,
               input  logic done,
               output logic [127:0] key, plaintext,
               input  logic [127:0] cyphertext);

    logic         sdodelayed, wasdone;
    logic [127:0] cyphertextcaptured;
               
    // assert load
    // apply 256 sclks to shift in key and plaintext, starting with plaintext[127]
    // then deassert load, wait until done
    // then apply 128 sclks to shift out cyphertext, starting with cyphertext[127]
    // SPI mode is equivalent to cpol = 0, cpha = 0 since data is sampled on first edge and the first
    // edge is a rising edge (clock going from low in the idle state to high).
    always_ff @(posedge sck)
        if (!wasdone)  {cyphertextcaptured, plaintext, key} = {cyphertext, plaintext[126:0], key, sdi};
        else           {cyphertextcaptured, plaintext, key} = {cyphertextcaptured[126:0], plaintext, key, sdi}; 
    
    // sdo should change on the negative edge of sck
    always_ff @(negedge sck) begin
        wasdone = done;
        sdodelayed = cyphertextcaptured[126];
    end
    
    // when done is first asserted, shift out msb before clock edge
    assign sdo = (done & !wasdone) ? cyphertext[127] : sdodelayed;
endmodule

/////////////////////////////////////////////
// aes_core
//   top level AES encryption module
//   when load is asserted, takes the current key and plaintext
//   generates cyphertext and asserts done when complete 11 cycles later
// 
//   See FIPS-197 with Nk = 4, Nb = 4, Nr = 10
//
//   The key and message are 128-bit values packed into an array of 16 bytes as
//   shown below
//        [127:120] [95:88] [63:56] [31:24]     S0,0    S0,1    S0,2    S0,3
//        [119:112] [87:80] [55:48] [23:16]     S1,0    S1,1    S1,2    S1,3
//        [111:104] [79:72] [47:40] [15:8]      S2,0    S2,1    S2,2    S2,3
//        [103:96]  [71:64] [39:32] [7:0]       S3,0    S3,1    S3,2    S3,3
//
//   Equivalently, the values are packed into four words as given
//        [127:96]  [95:64] [63:32] [31:0]      w[0]    w[1]    w[2]    w[3]
/////////////////////////////////////////////

module aes_core(input  logic         clk, 
                input  logic         load,
                input  logic [127:0] key, 
                input  logic [127:0] plaintext, 
                output logic         done, 
                output logic [127:0] cyphertext);
    // connect all the different submodules
    logic firstRound = 1;
    logic [3:0] bufferCount, roundCount;
    logic [31:0] rcon;
    logic [127:0] currentKey;
    logic [127:0] st, psb, sb, sr, pmc, mc, prc, nextWordsKey,rc;
    addRoundKey rk1(plaintext, key, st);

    subByte sb1(psb, clk, sb);
    shiftRows sr1(sb, sr);
    mixcolumns mc1(pmc, mc);
    generateNextWords nw1(clk, currentKey, rcon, nextWordsKey);
    addRoundKey rc1(prc, nextWordsKey,rc);
	
	always_ff @(posedge clk) begin
        // on reset reset done, roundCount, bufferCount
        if (load) begin
          roundCount <= 0;
          bufferCount <= 0;
	      done <= 0;
        end 
        else begin
          // Increment bufferCount on every clock cycle
          bufferCount <= bufferCount + 1;

          // we know a round is over after 3 clock cycles
          if (bufferCount > 3) begin
            psb <= rc;
              bufferCount <= 0; // Reset bufferCount after using it
              roundCount <= roundCount + 1; // Increment roundCount
              currentKey <= nextWordsKey; // Update currentKey
            end
        end

    // if its the beginning current key is set to input key
    if (roundCount == 0 & bufferCount == 0) begin
      currentKey <= key;
	    psb <= st;
    end

    // if its the end of cypher set cypher text to rc and done high
    if (roundCount == 9 && bufferCount == 2) begin
        cyphertext <= rc;
        done <= 1;
    end

    // if its round 10 skip mixColumns
    if(roundCount < 9) begin
      pmc <= sr;
      prc <= mc;
    end
    else begin // else set pre round key to shiftRows
      prc <= sr;
    end

    // rcon logic
    if (roundCount == 0) rcon = 32'h01000000;
    if (roundCount == 1) rcon = 32'h02000000;
    if (roundCount == 2) rcon = 32'h04000000;
    if (roundCount == 3) rcon = 32'h08000000;
    if (roundCount == 4) rcon = 32'h10000000;
    if (roundCount == 5) rcon = 32'h20000000;
    if (roundCount == 6) rcon = 32'h40000000;
    if (roundCount == 7) rcon = 32'h80000000;
    if (roundCount == 8) rcon = 32'h1b000000;
    if (roundCount == 9) rcon = 32'h36000000;
end
    
endmodule

/////////////////////////////////////////////
// sbox
//   Infamous AES byte substitutions with magic numbers
//   Synchronous version which is mapped to embedded block RAMs (EBR)
//   Section 5.1.1, Figure 7
/////////////////////////////////////////////
module sbox_sync(
	input		logic [7:0] a,
	input	 	logic 			clk,
	output 	logic [7:0] y);
            
  // sbox implemented as a ROM
  // This module is synchronous and will be inferred using BRAMs (Block RAMs)
  logic [7:0] sbox [0:255];

  initial   $readmemh("sbox.txt", sbox);
	
	// Synchronous version
	always_ff @(posedge clk) begin
		y <= sbox[a];
	end
endmodule

/////////////////////////////////////////////
// mixcolumns
//   Even funkier action on columns
//   Section 5.1.3, Figure 9
//   Same operation performed on each of four columns
/////////////////////////////////////////////

module mixcolumns(input  logic [127:0] a,
                  output logic [127:0] y);

  mixcolumn mc0(a[127:96], y[127:96]);
  mixcolumn mc1(a[95:64],  y[95:64]);
  mixcolumn mc2(a[63:32],  y[63:32]);
  mixcolumn mc3(a[31:0],   y[31:0]);
endmodule

/////////////////////////////////////////////
// mixcolumn
//   Perform Galois field operations on bytes in a column
//   See EQ(4) from E. Ahmed et al, Lightweight Mix Columns Implementation for AES, AIC09
//   for this hardware implementation
/////////////////////////////////////////////

module mixcolumn(input  logic [31:0] a,
                 output logic [31:0] y);
                      
        logic [7:0] a0, a1, a2, a3, y0, y1, y2, y3, t0, t1, t2, t3, tmp;
        
        assign {a0, a1, a2, a3} = a;
        assign tmp = a0 ^ a1 ^ a2 ^ a3;
    
        galoismult gm0(a0^a1, t0);
        galoismult gm1(a1^a2, t1);
        galoismult gm2(a2^a3, t2);
        galoismult gm3(a3^a0, t3);
        
        assign y0 = a0 ^ tmp ^ t0;
        assign y1 = a1 ^ tmp ^ t1;
        assign y2 = a2 ^ tmp ^ t2;
        assign y3 = a3 ^ tmp ^ t3;
        assign y = {y0, y1, y2, y3};    
endmodule

/////////////////////////////////////////////
// galoismult
//   Multiply by x in GF(2^8) is a left shift
//   followed by an XOR if the result overflows
//   Uses irreducible polynomial x^8+x^4+x^3+x+1 = 00011011
/////////////////////////////////////////////

module galoismult(input  logic [7:0] a,
                  output logic [7:0] y);

    logic [7:0] ashift;
    
    assign ashift = {a[6:0], 1'b0};
    assign y = a[7] ? (ashift ^ 8'b00011011) : ashift;
endmodule

/////////////////////////////////////////////
// shiftRows
//   cyclically shif the last three rows of 
//   the state 
/////////////////////////////////////////////
module shiftRows(input  logic [127:0] a,
                  output logic [127:0] y);
    // row 0
    assign y[127:120] = a[127:120];
    assign y[95:88] = a[95:88];
    assign y[63:56] = a[63:56];
    assign y[31:24] = a[31:24];

    // row 1
    assign y[119:112] = a[87:80];
    assign y[87:80] = a[55:48];
    assign y[55:48] = a[23:16];
    assign y[23:16] = a[119:112];

    // row 2
    assign y[111:104] = a[47:40];
    assign y[79:72] = a[15:8];
    assign y[47:40] = a[111:104];
    assign y[15:8] = a[79:72];

    //row 3
    assign y[103:96] = a[7:0];
    assign y[71:64] = a[103:96];
    assign y[39:32] = a[71:64];
    assign y[7:0] = a[39:32];
endmodule

/////////////////////////////////////////////
// subByte
//   substitute bytes from look up table
/////////////////////////////////////////////
module subByte(input logic [127:0] a, input logic clk,   
                output logic [127:0] y);
    // calculate subBytes
    logic [7:0] s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,s11,s12,s13,s14,s15;

    sbox_sync sbox_sync0(a[127:120], clk, s0);
    sbox_sync sbox_sync1(a[119:112], clk, s1);
    sbox_sync sbox_sync2(a[111:104], clk, s2);
    sbox_sync sbox_sync3(a[103:96], clk, s3);
    sbox_sync sbox_sync4(a[95:88], clk, s4);
    sbox_sync sbox_sync5(a[87:80], clk, s5);
    sbox_sync sbox_sync6(a[79:72], clk, s6);
    sbox_sync sbox_sync7(a[71:64], clk, s7);
    sbox_sync sbox_sync8(a[63:56], clk, s8);
    sbox_sync sbox_sync9(a[55:48], clk, s9);
    sbox_sync sbox_sync10(a[47:40], clk, s10);
    sbox_sync sbox_sync11(a[39:32], clk, s11);
    sbox_sync sbox_sync12(a[31:24], clk, s12);
    sbox_sync sbox_sync13(a[23:16], clk, s13);
    sbox_sync sbox_sync14(a[15:8], clk, s14);
    sbox_sync sbox_sync15(a[7:0], clk, s15);

    assign y = {s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,s11,s12,s13,s14,s15};

endmodule

/////////////////////////////////////////////
// generateNextWords
//   takes currentWord and rcone and 
//   calculates the nextWords for key expansion
/////////////////////////////////////////////
module generateNextWords(input clk, input logic [127:0] currentWords, input logic [31:0] rcon,
                          output logic [127:0] nextWords);
    logic [31:0] temp;
    assign temp = currentWords[31:0];
    logic [31:0] word0, word1, word2, word3;
    oneWord wrd0(clk, temp, rcon, currentWords[127:96], word0);
    assign word1 = word0 ^ currentWords[95:64];
    assign word2 = word1 ^ currentWords[63:32];
    assign word3 = word2 ^ currentWords[31:0];

    assign nextWords = {word0, word1, word2, word3};
   
endmodule

/////////////////////////////////////////////
// generateNextWords
//   takes a single word and the word[i-4]
//   calculates the nextWord for key expansion
/////////////////////////////////////////////
module oneWord(input logic clk,
                input logic [31:0] temp, rcon, wordFourBefore,
                output logic [31:0] word);
    // rotate word
    logic [31:0] afterRotWord, afterSubWord, afterRcon;
    logic [7:0] a0,a1,a2,a3;
    assign afterRotWord = {temp[23:0], temp[31:24]};

    //sub Word
    
    assign a0 = afterRotWord[31:24];
    assign a1 = afterRotWord[23:16];
    assign a2 = afterRotWord[15:8];
    assign a3 = afterRotWord[7:0];

    logic [7:0] s0,s1,s2,s3;

    sbox_sync sbox_sync0(a0, clk, s0);
    sbox_sync sbox_sync1(a1, clk, s1);
    sbox_sync sbox_sync2(a2, clk, s2);
    sbox_sync sbox_sync3(a3, clk, s3);

    assign afterSubWord = {s0,s1,s2,s3};

    // rcon
    assign afterRcon = afterSubWord ^ rcon;

    // xor it with word four before
    assign word = afterRcon ^ wordFourBefore;


endmodule

/////////////////////////////////////////////
// addRoundKey
//   substitute bytes from look up table
/////////////////////////////////////////////
module addRoundKey(input logic [127:0] a, input logic [127:0] key,  
                output logic [127:0] y);
    assign y = a^key;
endmodule