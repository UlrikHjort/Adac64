with System;
with Glib; use Glib;
with Cairo.Image_Surface; use Cairo.Image_Surface;
with Cairo.Surface;
with Cairo.Png;
with Types; use Types;
with Video; use Video;

package body Blit is

   function Width (S : Source) return Natural is
     (case S is when VIC_Screen => VIC_Visible_Width,
                when VDC_Screen => VDC_Width);
   function Height (S : Source) return Natural is
     (case S is when VIC_Screen => VIC_Visible_Lines,
                when VDC_Screen => VDC_Height);

   procedure Copy (S : Source; Surface : Cairo.Cairo_Surface) is
      W : constant Natural := Width (S);
      H : constant Natural := Height (S);
      Stride : constant Natural := Natural (Get_Stride (Surface)) / 4;
      Addr : constant System.Address := Get_Data_Generic (Surface);
      type Pixels is array (0 .. H - 1, 0 .. Stride - 1) of Pixel;
      Dst : Pixels;
      for Dst'Address use Addr;
      pragma Import (Ada, Dst);
   begin
      Cairo.Surface.Flush (Surface);
      for Y in 0 .. H - 1 loop
         for X in 0 .. W - 1 loop
            Dst (Y, X) := (case S is
                              when VIC_Screen => VIC_FB (Y, X),
                              when VDC_Screen => VDC_FB (Y, X));
         end loop;
      end loop;
      Cairo.Surface.Mark_Dirty (Surface);
   end Copy;

   procedure Save_PNG (S : Source; Path : String) is
      Surf : constant Cairo.Cairo_Surface :=
        Create (Cairo_Format_RGB24, Gint (Width (S)), Gint (Height (S)));
      Status : Cairo.Cairo_Status;
   begin
      Copy (S, Surf);
      Status := Cairo.Png.Write_To_Png (Surf, Path);
      pragma Unreferenced (Status);
      Cairo.Surface.Destroy (Surf);
   end Save_PNG;

end Blit;
