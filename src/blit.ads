--  Copying the emulator framebuffers into Cairo surfaces, and PNG export.

with Cairo;

package Blit is

   type Source is (VIC_Screen, VDC_Screen);

   function Width (S : Source) return Natural;
   function Height (S : Source) return Natural;

   procedure Copy (S : Source; Surface : Cairo.Cairo_Surface);
   --  Surface must be an RGB24 image surface of the source's size.

   procedure Save_PNG (S : Source; Path : String);

end Blit;
