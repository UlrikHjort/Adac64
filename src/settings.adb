with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;

package body Settings is

   package Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

   Values : Maps.Map;

   function Dir return String is
     ((if Ada.Environment_Variables.Exists ("HOME")
       then Ada.Environment_Variables.Value ("HOME") else ".") &
      "/.config/adac64");

   function Path return String is (Dir & "/settings");

   procedure Load is
      F : File_Type;
   begin
      Values.Clear;
      if not Ada.Directories.Exists (Path) then
         return;
      end if;
      Open (F, In_File, Path);
      while not End_Of_File (F) loop
         declare
            Line : constant String := Get_Line (F);
            Eq : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
         begin
            if Eq > Line'First and then Line (Line'First) /= '#' then
               Values.Include (Line (Line'First .. Eq - 1),
                               Line (Eq + 1 .. Line'Last));
            end if;
         end;
      end loop;
      Close (F);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Load;

   procedure Save is
      F : File_Type;
   begin
      if not Ada.Directories.Exists (Dir) then
         Ada.Directories.Create_Path (Dir);
      end if;
      Create (F, Out_File, Path);
      Put_Line (F, "# AdaC64 settings");
      for C in Values.Iterate loop
         Put_Line (F, Maps.Key (C) & "=" & Maps.Element (C));
      end loop;
      Close (F);
   exception
      when others =>
         if Is_Open (F) then
            Close (F);
         end if;
   end Save;

   function Get (Key : String; Default : String := "") return String is
     (if Values.Contains (Key) then Values.Element (Key) else Default);

   function Get (Key : String; Default : Boolean) return Boolean is
     (if Values.Contains (Key) then Values.Element (Key) = "1" else Default);

   function Get (Key : String; Default : Integer) return Integer is
   begin
      if Values.Contains (Key) then
         return Integer'Value (Values.Element (Key));
      end if;
      return Default;
   exception
      when others => return Default;
   end Get;

   procedure Set (Key : String; Value : String) is
   begin
      Values.Include (Key, Value);
   end Set;

   procedure Set (Key : String; Value : Boolean) is
   begin
      Set (Key, (if Value then "1" else "0"));
   end Set;

   procedure Set (Key : String; Value : Integer) is
   begin
      Set (Key, Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Left));
   end Set;

end Settings;
