--  Persistent user settings: simple "key=value" lines in
--  ~/.config/adac64/settings.

package Settings is

   procedure Load;
   procedure Save;

   function Get (Key : String; Default : String := "") return String;
   function Get (Key : String; Default : Boolean) return Boolean;
   function Get (Key : String; Default : Integer) return Integer;

   procedure Set (Key : String; Value : String);
   procedure Set (Key : String; Value : Boolean);
   procedure Set (Key : String; Value : Integer);

end Settings;
