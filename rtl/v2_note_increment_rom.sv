module v2_note_increment_rom(input logic [7:0] note, output logic [31:0] increment);
 always_comb begin case(note)
 57:increment=32'd19685267;60:increment=32'd23409859;62:increment=32'd26276679;64:increment=32'd29494575;67:increment=32'd35075158;69:increment=32'd39370534;72:increment=32'd46819719;default:increment=0;
 endcase end
endmodule
