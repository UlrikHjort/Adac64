--  Framebuffers and palettes shared between the video chips and the GUI.

with Types; use Types;

package Video is

   --  VIC-II output (PAL): 384 x 272 visible pixels
   VIC_Width  : constant := 384;
   VIC_Height : constant := 272;
   First_Visible_Line : constant := 16;

   type VIC_Frame is array (0 .. VIC_Height - 1, 0 .. VIC_Width - 1) of Pixel;
   VIC_FB : VIC_Frame := (others => (others => 0));

   --  VDC (8563) output: up to 640 x 200 text/bitmap area plus border
   VDC_Width  : constant := 704;
   VDC_Height : constant := 264;

   type VDC_Frame is array (0 .. VDC_Height - 1, 0 .. VDC_Width - 1) of Pixel;
   VDC_FB : VDC_Frame := (others => (others => 0));

   type Palette is array (Byte range 0 .. 15) of Pixel;

   --  "Pepto" PAL VIC-II palette
   VIC_Palette : constant Palette :=
     (16#000000#, 16#FFFFFF#, 16#68372B#, 16#70A4B2#,
      16#6F3D86#, 16#588D43#, 16#352879#, 16#B8C76F#,
      16#6F4F25#, 16#433900#, 16#9A6759#, 16#444444#,
      16#6C6C6C#, 16#9AD284#, 16#6C5EB5#, 16#959595#);

   --  RGBI palette used by the VDC (bit 3 = R, 2 = G, 1 = B, 0 = I)
   VDC_Palette : constant Palette :=
     (16#000000#, 16#555555#, 16#0000AA#, 16#5555FF#,
      16#00AA00#, 16#55FF55#, 16#00AAAA#, 16#55FFFF#,
      16#AA0000#, 16#FF5555#, 16#AA00AA#, 16#FF55FF#,
      16#AA5500#, 16#FFFF55#, 16#AAAAAA#, 16#FFFFFF#);

end Video;
