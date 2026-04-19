-- Returns stock KOReader Button unchanged.
-- Alpha patching for chess piece icons is handled entirely in buttontable.lua,
-- which is guaranteed to be loaded before any board buttons are constructed.
return require("ui/widget/button")
