// MIDI note -> 32-bit phase increment for a 48 kHz sample rate.
// increment = round(f * 2^32 / 48000), f = 440 * 2^((note-69)/12) (A4 = 440).
// The eight G natural minor degrees are 55 57 58 60 62 63 65 67
// (G3 A3 Bb3 C4 D4 Eb4 F4 G4).  The old pentatonic entries 64/69/72 are kept
// so a WT_PLAY test note written before this change still has an increment;
// the LIVE map no longer emits them.
module v2_note_increment_rom(input logic [7:0] note, output logic [31:0] increment);
 always_comb begin case(note)
 55:increment=32'd17537579;57:increment=32'd19685267;58:increment=32'd20855814;60:increment=32'd23409859;62:increment=32'd26276679;63:increment=32'd27839171;64:increment=32'd29494575;65:increment=32'd31248413;67:increment=32'd35075158;69:increment=32'd39370534;72:increment=32'd46819719;default:increment=0;
 endcase end
 endmodule
