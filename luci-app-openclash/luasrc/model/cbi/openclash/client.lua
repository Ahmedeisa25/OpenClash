
m = SimpleForm("openclash",translate("OpenClash"))
m.description = translate("A Mihomo(Clash) Client For OpenWrt").." — MT7621 lite (nft / Fake-IP / Rule)"
m.reset = false
m.submit = false

m:section(SimpleSection).template = "openclash/status"

return m
