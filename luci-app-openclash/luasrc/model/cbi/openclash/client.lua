
local NXFS = require "nixio.fs"
local SYS = require "luci.sys"
local HTTP = require "luci.http"
local DISP = require "luci.dispatcher"
local UTIL = require "luci.util"
local fs = require "luci.openclash"
local uci = require("luci.model.uci").cursor()

m = SimpleForm("openclash",translate("OpenClash"))
m.description = translate("A Mihomo(Clash) Client For OpenWrt").." — MT7621 lite (nft / Fake-IP / Rule)"
m.reset = false
m.submit = false

m:section(SimpleSection).template = "openclash/status"

return m
