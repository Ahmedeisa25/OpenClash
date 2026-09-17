
local NXFS = require "nixio.fs"
local SYS = require "luci.sys"
local HTTP = require "luci.http"
local DISP = require "luci.dispatcher"
local UTIL = require "luci.util"
local fs = require "luci.openclash"
local uci = require "luci.model.uci".cursor()
local json = require "luci.jsonc"
local datatype = require "luci.cbi.datatypes"
local net = require "luci.model.network".init()
local devices = {}
for _, iface in ipairs(net:get_interfaces()) do
	if iface:name() then
		table.insert(devices, {name = iface:name()})
	end
end

-- 优化 CBI UI（新版 LuCI 专用）
local function optimize_cbi_ui()
	HTTP.write([[
		<script type="text/javascript">
			// 修正上移、下移按钮名称
			document.querySelectorAll("input.btn.cbi-button.cbi-button-up").forEach(function(btn) {
				btn.value = "]] .. translate("Move up") .. [[";
			});
			document.querySelectorAll("input.btn.cbi-button.cbi-button-down").forEach(function(btn) {
				btn.value = "]] .. translate("Move down") .. [[";
			});
			// 删除控件和说明之间的多余换行
			document.querySelectorAll("div.cbi-value-description").forEach(function(descDiv) {
				var prev = descDiv.previousSibling;
				while (prev && prev.nodeType === Node.TEXT_NODE && prev.textContent.trim() === "") {
					prev = prev.previousSibling;
				}
				if (prev && prev.nodeType === Node.ELEMENT_NODE && prev.tagName === "BR") {
					prev.remove();
				}
			});
		</script>
	]])
end

font_green = [[<b style=color:green>]]
font_red = [[<b style=color:red>]]
font_off = [[</b>]]
bold_on = [[<strong>]]
bold_off = [[</strong>]]

local op_mode = "fake-ip"
local lan_ip = fs.lanip()
m = Map("openclash", translate("Plugin Settings"))
m.pageaction = false
m.description = translate("Lite profile: nftables + Fake-IP + Rule mode for MT7621 / 128MB RAM")..
"<br/>"..translate("Note: To restore the default configuration, try accessing:").." <a href='javascript:void(0)' onclick='javascript:restore_config(this)'>http://"..lan_ip.."/cgi-bin/luci/admin/services/openclash/restore</a>"

s = m:section(TypedSection, "openclash")
s.anonymous = true

s:tab("op_mode", translate("Operation Mode"))
s:tab("traffic_control", translate("Traffic Control"))
s:tab("dns", "DNS "..translate("Settings"))
s:tab("lan_ac", translate("Black&White"))
s:tab("dashboard", translate("Dashboard Settings"))
s:tab("geo_update", translate("GEO Update"))
s:tab("chnr_update", translate("Chnroute Update"))
s:tab("auto_restart", translate("Auto Restart"))
s:tab("debug", translate("Core Tests"))
s:tab("version_update", translate("Version Update"))

o = s:taboption("op_mode", ListValue, "en_mode", font_red..bold_on..translate("Select Mode")..bold_off..font_off)
o.description = translate("Lite build is locked to Fake-IP + nftables (no TUN / redir-host)")
o:value("fake-ip", translate("fake-ip"))
o.default = "fake-ip"

o = s:taboption("op_mode", Flag, "enable_udp_proxy", translate("Proxy UDP Traffics"))
o.description = translate("The Servers Must Support UDP forwarding").."<br>"..font_red..bold_on.."1."..translate("If Docker is Installed, UDP May Not Forward Normally").."<br>2."..translate("In Fake-ip Mode, Even If This Option is Turned Off, Domain Type Connections Still Pass Through The Core For The Availability")..bold_off..font_off
o:depends("en_mode", "redir-host")
o:depends("en_mode", "fake-ip")
o.default = 1

o = s:taboption("op_mode", ListValue, "proxy_mode", translate("Proxy Mode"))
o.description = translate("Select Proxy Mode")
o:value("rule", translate("Rule Proxy Mode"))
o:value("global", translate("Global Proxy Mode"))
o:value("direct", translate("Direct Proxy Mode"))
o.default = "rule"

o = s:taboption("op_mode", Value, "delay_start", translate("Delay Start (s)"))
o.description = translate("Delay Start On Boot")
o.default = "0"
o.datatype = "uinteger"

o = s:taboption("op_mode", Value, "log_size", translate("Log Size (KB)"))
o.description = translate("Set Log File Size (KB)")
o.default = "1024"

o = s:taboption("op_mode", Flag, "bypass_gateway_compatible", translate("Bypass Gateway Compatible"))
o.description = translate("If The Network Cannot be Connected in Bypass Gateway Mode, Please Try to Enable.")..font_red..bold_on..translate("Suggestion: If The Device Does Not Have WLAN, Please Disable The Lan Interface's Bridge Option")..bold_off..font_off
o.default = 0

o = s:taboption("op_mode", Flag, "disable_quic_go_gso", translate("Disable quic-go GSO Support"))
o.description = font_red..bold_on..translate("Suggestion: If Encountering Issues With QUIC UDP on The Linux Kernel Version Above 6.6, Please Try to Enable.")..bold_off..font_off
o.default = 0

o = s:taboption("op_mode", Flag, "small_flash_memory", translate("Small Flash Memory"))
o.description = translate("Move Core And GEOIP Data File To /tmp/etc/openclash For Small Flash Memory Device")
o.default = 0

---- DNS Settings
o = s:taboption("dns", ListValue, "enable_redirect_dns", font_red..bold_on..translate("Redirect Local DNS Setting")..bold_off..font_off)
o.description = translate("Set Local DNS Redirect")
o.default = 1
o:value("0", translate("Disable"))
o:value("1", translate("Dnsmasq Redirect"))
o:value("2", translate("Firewall Redirect"))

o = s:taboption("dns", DummyValue, "flush_dns_cache", translate("Flush DNS"))
o.template = "openclash/flush_dns_cache"

o = s:taboption("dns", Button, "dnsmasq_fix", translate("Dnsmasq Fix"))
o.description = translate("If DNS is abnormal after stopping the OpenClash, please try to fix")
o.inputtitle = translate("Fix")
o.inputstyle = "reload"
o.write = function()
	uci:set("dhcp", "@dnsmasq[0]", "noresolv", "0")
	uci:set("dhcp", "@dnsmasq[0]", "localuse", "1")
	local resolv_file = uci:get("dhcp", "@dnsmasq[0]", "resolvfile")
	local need_fix = false
	if not resolv_file or resolv_file == "" then
		need_fix = true
	elseif not NXFS.access(resolv_file) then
		need_fix = true
	else
		local content = fs.readfile(resolv_file) or ""
		if not content:find("nameserver") then
			need_fix = true
		end
	end
	if need_fix then
		for _, f in ipairs({"/tmp/resolv.conf.d/resolv.conf.auto", "/tmp/resolv.conf.auto"}) do
			if NXFS.access(f) then
				local content = fs.readfile(f) or ""
				if content:find("nameserver") then
					uci:set("dhcp", "@dnsmasq[0]", "resolvfile", f)
					resolv_file = f
					need_fix = false
					break
				end
			end
		end
	end
	if need_fix then
		resolv_file = "/tmp/resolv.conf.d/resolv.conf.auto"
		SYS.call("mkdir -p /tmp/resolv.conf.d")
		fs.writefile(resolv_file, "# Interface lan\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n")
		uci:set("dhcp", "@dnsmasq[0]", "resolvfile", resolv_file)
	end
	uci:set("openclash", "config", "redirect_dns", "0")
	uci:commit("dhcp")
	uci:commit("openclash")
	SYS.call("/etc/init.d/dnsmasq restart")
	HTTP.redirect(DISP.build_url("admin", "services", "openclash", "settings"))
end

o = s:taboption("dns", Flag, "enable_custom_domain_dns_server", translate("Enable Specify DNS Server"))
o.default = 0
o:depends("enable_redirect_dns", "1")
o:depends("enable_redirect_dns", "0")

o = s:taboption("dns", Value, "custom_domain_dns_server", translate("Specify DNS Server"))
o.description = translate("Specify DNS Server For List, Only One IP Server Address Support")
o.default = "114.114.114.114"
o.placeholder = translate("114.114.114.114 or 127.0.0.1#5300")
o:depends{enable_redirect_dns = "1", enable_custom_domain_dns_server = "1"}

custom_domain_dns = s:taboption("dns", Value, "custom_domain_dns")
custom_domain_dns.template = "cbi/tvalue"
custom_domain_dns.description = translate("Domain Names In The List Do Not Return Fake-IP, One rule per line, Depend on Dnsmasq")
custom_domain_dns.rows = 20
custom_domain_dns.wrap = "off"
custom_domain_dns:depends{enable_redirect_dns = "1", enable_custom_domain_dns_server = "1"}

function custom_domain_dns.cfgvalue(self, section)
	return fs.readfile("/etc/openclash/custom/openclash_custom_domain_dns.list") or ""
end
function custom_domain_dns.write(self, section, value)
	if value then
		value = value:gsub("\r\n?", "\n")
		local old_value = fs.readfile("/etc/openclash/custom/openclash_custom_domain_dns.list")
	if value ~= old_value then
			fs.writefile("/etc/openclash/custom/openclash_custom_domain_dns.list", value)
		end
	end
	return true
end

---- Access Control
o = s:taboption("lan_ac", ListValue, "lan_ac_mode", translate("LAN Access Control Mode"))
o.description = font_red..bold_on..translate("To Use in Fake-IP Mode, Please Switch The Dns Redirect Mode To Firewall Forwarding")..bold_off..font_off
o:value("0", translate("Black List Mode"))
o:value("1", translate("White List Mode"))
o.default = "0"
o:depends("enable_redirect_dns", "2")
o:depends("en_mode", "redir-host")
o:depends("en_mode", "redir-host-tun")
o:depends("en_mode", "redir-host-mix")

ip_b = s:taboption("lan_ac", DynamicList, "lan_ac_black_ips", translate("LAN Bypassed Host List"))
ip_b.datatype = "ipmask"
ip_b:depends({lan_ac_mode = "0", enable_redirect_dns = "2"})
ip_b:depends({lan_ac_mode = "0", en_mode = "redir-host"})
ip_b:depends({lan_ac_mode = "0", en_mode = "redir-host-tun"})
ip_b:depends({lan_ac_mode = "0", en_mode = "redir-host-mix"})

mac_b = s:taboption("lan_ac", DynamicList, "lan_ac_black_macs", translate("LAN Bypassed Mac List"))
mac_b.datatype = "list(macaddr)"
mac_b.rmempty = true
mac_b:depends("lan_ac_mode", "0")

ip_w = s:taboption("lan_ac", DynamicList, "lan_ac_white_ips", translate("LAN Proxied Host List"))
ip_w.datatype = "ipmask"
ip_w:depends({lan_ac_mode = "1", enable_redirect_dns = "2"})
ip_w:depends({lan_ac_mode = "1", en_mode = "redir-host"})
ip_w:depends({lan_ac_mode = "1", en_mode = "redir-host-tun"})
ip_w:depends({lan_ac_mode = "1", en_mode = "redir-host-mix"})

mac_w = s:taboption("lan_ac", DynamicList, "lan_ac_white_macs", translate("LAN Proxied Mac List"))
mac_w.datatype = "list(macaddr)"
mac_w.rmempty = true
mac_w:depends("lan_ac_mode", "1")

o = s:taboption("lan_ac", DynamicList, "wan_ac_black_ips", translate("WAN Bypassed Host List"))
o.datatype = "ipmask"
o.description = translate("In The Fake-IP Mode, Only Pure IP Requests Are Supported, Please Setting Fake-IP-Filter First If You Need Domain Type Requests")

o = s:taboption("lan_ac", DynamicList, "wan_ac_black_ports", translate("WAN Bypassed Port List"))
o.datatype = "or(port, portrange)"
o.description = translate("In The Fake-IP Mode, Only Pure IP Requests Are Supported, Please Setting Fake-IP-Filter First If You Need Domain Type Requests")

s2 = m:section(TypedSection, "lan_ac_traffic", translate("Lan Traffic Access List"),
	"1. "..translate("The Traffic From The Local Specified Port Will Not Pass The Core, Try To Set When The Bypass Gateway Forwarding Fails").."; ".."2. "..translate("In The Fake-IP Mode, Only Pure IP Requests Are Supported, Please Setting Fake-IP-Filter First If You Need Domain Type Requests"))

s2.template = "cbi/tblsection"
s2.sortable = true
s2.anonymous = true
s2.addremove = true
s2.rmempty = false
s2.render = function(self, ...)
	Map.render(self, ...)
	if type(optimize_cbi_ui) == "function" then
		optimize_cbi_ui()
	end
end

o = s2:option(Value, "comment", translate("Comment"))
o.rmempty = true

o = s2:option(Flag, "enabled", translate("Enable"))
o.rmempty = false
o.default = o.enabled
o.cfgvalue = function(...)
	return Flag.cfgvalue(...) or "1"
end

ip_ac = s2:option(Value, "src_ip", translate("Internal addresses"))
ip_ac.datatype = "or(ipmask, string)"
ip_ac.placeholder = "0.0.0.0/0"
ip_ac.rmempty = true
ip_ac:value("localnetwork", translate("Local Network"))

o = s2:option(Value, "src_port", translate("Internal ports"))
o.datatype = "or(port, portrange)"
o.placeholder = translate("5000 or 1234-2345")
o.rmempty = true

o = s2:option(ListValue, "proto", translate("Proto"))
o:value("both", translate("Both"))
o:value("udp", translate("UDP"))
o:value("tcp", translate("TCP"))
o.default = "both"
o.rmempty = false

o = s2:option(ListValue, "family", translate("Family"))
o:value("ipv4", translate("IPv4"))
o.default = "ipv4"
o.rmempty = false

o = s2:option(ListValue, "interface", translate("Interface"))
o:value("")
o.default = ""
for _, dev in ipairs(devices) do
	o:value(dev.name)
end
o.rmempty = true

o = s2:option(ListValue, "user", translate("User"))
o:value("")
o.default = ""
local passwd_content = fs.readfile("/etc/passwd")
local users = ""
if passwd_content then
    for line in string.gmatch(passwd_content, "[^\n]+") do
        if line:match("^[^#]") and line:match(":") then
            local fields = {}
            for field in string.gmatch(line, "([^:]+)") do
                table.insert(fields, field)
            end
            if #fields >= 3 then
                local username = fields[1]
                local uid_str = fields[3]
                local uid = tonumber(uid_str)
                if uid and uid >= 0 then
                    users = users .. uid .. ":" .. username .. "\n"
                end
            end
        end
    end
end
for uid, username in string.gmatch(users, "(%d+):(%S+)") do
    o:value(uid, username)
end
o.rmempty = true

o = s2:option(Value, "dscp", translate("DSCP"))
o.datatype = "range(0,63)"
o.rmempty = true
function o.validate(self, value)
	if value == "" or value == nil then
		return value
	end
	local num = tonumber(value)
	if not num or num < 0 or num > 63 then
		return nil, "DSCP must be between 0 and 63"
	end
	return value
end

o = s2:option(ListValue, "target", translate("Target"))
o:value("return", translate("RETURN"))
o:value("accept", translate("ACCEPT"))
o:value("drop", translate("DROP"))
o.rmempty = false

local function ip_compare(a, b)
	local function ipv4_to_number(ip)
		local p1, p2, p3, p4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		if p1 and p2 and p3 and p4 then
			local n1, n2, n3, n4 = tonumber(p1), tonumber(p2), tonumber(p3), tonumber(p4)
			if n1 <= 255 and n2 <= 255 and n3 <= 255 and n4 <= 255 then
				return n1 * 16777216 + n2 * 65536 + n3 * 256 + n4
			end
		end
		return 0
	end

	local a_is_ipv4 = datatype.ip4addr(a.dest)
	local b_is_ipv4 = datatype.ip4addr(b.dest)

	if a_is_ipv4 and not b_is_ipv4 then
		return true
	elseif not a_is_ipv4 and b_is_ipv4 then
		return false
	elseif a_is_ipv4 and b_is_ipv4 then
		return ipv4_to_number(a.dest) < ipv4_to_number(b.dest)
	else
		return a.dest < b.dest
	end
end

local all_neighbors = {}

luci.ip.neighbors({ family = 4 }, function(n)
	if n.mac and n.dest then
		if n.hostname then
			hostname = " [".. n.hostname .."]"
		end
		table.insert(all_neighbors, {dest = n.dest:string(), mac = n.mac, hostname = hostname or "", family = 4})
	end
end)


table.sort(all_neighbors, ip_compare)

local mac_ip_map = {}
local mac_order = {}
local mac_hostname_map = {}

for _, item in ipairs(all_neighbors) do
	ip_b:value(item.dest, "%s%s" %{ item.dest, item.hostname })
	ip_w:value(item.dest, "%s%s" %{ item.dest, item.hostname })
	ip_ac:value(item.dest, "%s%s" %{ item.dest, item.hostname })
	if not mac_ip_map[item.mac] then
		mac_ip_map[item.mac] = {}
		table.insert(mac_order, item.mac)
	end
	table.insert(mac_ip_map[item.mac], item.dest)
	if not mac_hostname_map[item.mac] then
		mac_hostname_map[item.mac] = item.hostname
	end
end

for _, mac in ipairs(mac_order) do
	local ips = mac_ip_map[mac]
	table.sort(ips, function(a, b)
		local a_is_ipv4 = datatype.ip4addr(a)
		local b_is_ipv4 = datatype.ip4addr(b)
		if a_is_ipv4 and not b_is_ipv4 then
			return true
		elseif not a_is_ipv4 and b_is_ipv4 then
			return false
		elseif a_is_ipv4 and b_is_ipv4 then
			local function ipv4_to_number(ip)
				local p1, p2, p3, p4 = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
				return p1 and p2 and p3 and p4 and (tonumber(p1)*16777216+tonumber(p2)*65536+tonumber(p3)*256+tonumber(p4)) or 0
			end
			return ipv4_to_number(a) < ipv4_to_number(b)
		else
			return a < b
		end
	end)
	local ip_str = table.concat(ips, "|")
	mac_b:value(mac, "%s%s (%s)" %{ mac, mac_hostname_map[mac], ip_str })
	mac_w:value(mac, "%s%s (%s)" %{ mac, mac_hostname_map[mac], ip_str })
end

---- Traffic Control
o = s:taboption("traffic_control", Flag, "router_self_proxy", font_red..bold_on..translate("Router-Self Proxy")..bold_off..font_off)
o.description = translate("Only Supported for Rule Mode")..", "..font_red..bold_on..translate("ALL Functions In Stream Enhance Tag Will Not Work After Disable")..bold_off..font_off
o.default = 1

o = s:taboption("traffic_control", Flag, "disable_udp_quic", font_red..bold_on..translate("Disable QUIC")..bold_off..font_off)
o.description = translate("Prevent YouTube and Others To Use QUIC Transmission")..", "..font_red..bold_on..translate("REJECT UDP Traffic(Not Include bypassed regions via China IP Route setting) On Port 443")..bold_off..font_off
o.default = 1

o = s:taboption("traffic_control", Flag, "skip_proxy_address", translate("Skip Proxy Address"))
o.description = translate("Bypassing Server Addresses And Preventing Duplicate Proxies")
o.default = 0

o = s:taboption("traffic_control", Value, "common_ports", font_red..bold_on..translate("Common Ports Proxy Mode")..bold_off..font_off)
o.description = translate("Only Common Ports, Prevent BT/P2P Passing")
o:value("0", translate("Disable"))
o:value("21 22 23 53 80 123 143 194 443 465 587 853 993 995 998 2052 2053 2082 2083 2086 2095 2096 2197 5222 5223 5228 5229 5230 8080 8443 8880 8888 8889", translate("Default Common Ports"))
o.default = 0
o.placeholder = translate("443 or 21-443, Use Space to Separate")
o:depends("en_mode", "redir-host")
o:depends("en_mode", "redir-host-tun")
o:depends("en_mode", "redir-host-mix")

o = s:taboption("traffic_control", ListValue, "china_ip_route", translate("China IP Route"))
o.description = translate("Bypass Specified Regions Network Flows, Improve Performance, If Inaccessibility on Bypass Gateway, Try to Enable Bypass Gateway Compatible Option")
o.default = 0
o:value("0", translate("Disable"))
o:value("1", translate("Bypass Mainland China"))
o:value("2", translate("Bypass Overseas"))

o = s:taboption("traffic_control", Flag, "intranet_allowed", translate("Only intranet allowed"))
o.description = translate("When Enabled, The Control Panel And The Connection Broker Port Will Not Be Accessible From The Public Network")
o.default = 1

o = s:taboption("traffic_control", DynamicList, "intranet_allowed_wan_name", translate("WAN Interface Name"))
o.description = translate("Select WAN Interface Name For The Intranet Allowed")
o:depends("intranet_allowed", "1")
for _, dev in ipairs(devices) do
	o:value(dev.name)
end

o = s:taboption("traffic_control", ListValue, "lan_interface_name", translate("LAN Interface Name"))
o.description = translate("Select LAN Interface Name")
o:value("0", translate("Disable"))
o.default = "0"
for _, dev in ipairs(devices) do
	o:value(dev.name)
end

o = s:taboption("traffic_control", Value, "local_network_pass", translate("Local IPv4 Network Bypassed List"))
o.template = "cbi/tvalue"
o.description = translate("The Traffic of The Destination For The Specified Address Will Not Pass The Core")
o.rows = 20
o.wrap = "off"

function o.cfgvalue(self, section)
	return fs.readfile("/etc/openclash/custom/openclash_custom_localnetwork_ipv4.list") or ""
end
function o.write(self, section, value)
	if value then
		value = value:gsub("\r\n?", "\n")
		local old_value = fs.readfile("/etc/openclash/custom/openclash_custom_localnetwork_ipv4.list")
		if value ~= old_value then
			fs.writefile("/etc/openclash/custom/openclash_custom_localnetwork_ipv4.list", value)
		end
	end
	return true
end

o = s:taboption("traffic_control", Value, "chnroute_pass", translate("Chnroute Bypassed List"))
o.template = "cbi/tvalue"
o.description = translate("Domains or IPs in The List Will Not be Affected by The China IP Route Option, Depend on Dnsmasq")
o.rows = 20
o.wrap = "off"
o:depends("enable_redirect_dns", "1")
o:depends("enable_redirect_dns", "0")

function o.cfgvalue(self, section)
	return fs.readfile("/etc/openclash/custom/openclash_custom_chnroute_pass.list") or ""
end
function o.write(self, section, value)
	if value then
		value = value:gsub("\r\n?", "\n")
		local old_value = fs.readfile("/etc/openclash/custom/openclash_custom_chnroute_pass.list")
		if value ~= old_value then
			fs.writefile("/etc/openclash/custom/openclash_custom_chnroute_pass.list", value)
		end
	end
	return true
end

--Stream Enhance
---- update Settings
o = s:taboption("geo_update", Flag, "geo_auto_update", font_red..bold_on..translate("Auto Update GeoIP MMDB")..bold_off..font_off)
o.default = 0

o = s:taboption("geo_update", ListValue, "geo_update_week_time", translate("Update Time (Every Week)"))
o:value("*", translate("Every Day"))
o:value("1", translate("Every Monday"))
o:value("2", translate("Every Tuesday"))
o:value("3", translate("Every Wednesday"))
o:value("4", translate("Every Thursday"))
o:value("5", translate("Every Friday"))
o:value("6", translate("Every Saturday"))
o:value("0", translate("Every Sunday"))
o.default = "1"
o:depends("geo_auto_update", "1")

o = s:taboption("geo_update", ListValue, "geo_update_day_time", translate("Update time (every day)"))
for t = 0,23 do
o:value(t, t..":00")
end
o.default = "0"
o:depends("geo_auto_update", "1")

o = s:taboption("geo_update", Value, "geo_custom_url")
o.title = translate("Custom GeoIP MMDB URL")
o.rmempty = true
o.description = translate("Custom GeoIP MMDB URL, Click Button Below To Refresh After Edit")
o:value("https://testingcf.jsdelivr.net/gh/alecthw/mmdb_china_ip_list@release/lite/Country.mmdb", translate("Alecthw-lite-testingcf-Version")..translate("(Default mmdb)"))
o:value("https://testingcf.jsdelivr.net/gh/alecthw/mmdb_china_ip_list@release/Country.mmdb", translate("Alecthw-testingcf-Version")..translate("(All Info mmdb)"))
o:value("https://testingcf.jsdelivr.net/gh/Hackl0us/GeoIP2-CN@release/Country.mmdb", translate("Hackl0us-testingcf-Version")..translate("(Only CN)"))
o:value("https://github.com/alecthw/mmdb_china_ip_list/releases/latest/download/Country-lite.mmdb", translate("Alecthw-lite-github-Version"))
o.default = "https://testingcf.jsdelivr.net/gh/alecthw/mmdb_china_ip_list@release/lite/Country.mmdb"
o:depends("geo_auto_update", "1")

o = s:taboption("geo_update", Button, translate("GEOIP Update")) 
o.title = translate("Update GeoIP MMDB")
o.description = translate("Current Version:").." "..font_green..bold_on..fs.get_resourse_mtime("/etc/openclash/Country.mmdb")..bold_off..font_off
o.inputtitle = translate("Check And Update")
o.inputstyle = "reload"
o.write = function()
	m.uci:set("openclash", "config", "enable", 1)
	m.uci:commit("openclash")
	SYS.call("/usr/share/openclash/openclash_geo.sh ipdb >/dev/null 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "openclash"))
end

o = s:taboption("geo_update", Flag, "geoip_auto_update", font_red..bold_on..translate("Auto Update GeoIP Dat")..bold_off..font_off)
o.default = 0

o = s:taboption("geo_update", ListValue, "geoip_update_week_time", translate("Update Time (Every Week)"))
o:value("*", translate("Every Day"))
o:value("1", translate("Every Monday"))
o:value("2", translate("Every Tuesday"))
o:value("3", translate("Every Wednesday"))
o:value("4", translate("Every Thursday"))
o:value("5", translate("Every Friday"))
o:value("6", translate("Every Saturday"))
o:value("0", translate("Every Sunday"))
o.default = "1"
o:depends("geoip_auto_update", "1")

o = s:taboption("geo_update", ListValue, "geoip_update_day_time", translate("Update time (every day)"))
for t = 0,23 do
o:value(t, t..":00")
end
o.default = "0"
o:depends("geoip_auto_update", "1")

o = s:taboption("geo_update", Value, "geoip_custom_url")
o.title = translate("Custom GeoIP Dat URL")
o.rmempty = true
o.description = translate("Custom GeoIP Dat URL, Click Button Below To Refresh After Edit")
o:value("https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat", translate("Loyalsoldier-testingcf-jsdelivr-Version")..translate("(Default)"))
o:value("https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat", translate("Loyalsoldier-fastly-jsdelivr-Version"))
o:value("https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat", translate("Loyalsoldier-github-Version"))
o.default = "https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
o:depends("geoip_auto_update", "1")

o = s:taboption("geo_update", Button, translate("GEOIP Dat Update")) 
o.title = translate("Update GeoIP Dat")
o.description = translate("Current Version:").." "..font_green..bold_on..fs.get_resourse_mtime("/etc/openclash/GeoIP.dat")..bold_off..font_off
o.inputtitle = translate("Check And Update")
o.inputstyle = "reload"
o.write = function()
	m.uci:set("openclash", "config", "enable", 1)
	m.uci:commit("openclash")
	SYS.call("/usr/share/openclash/openclash_geo.sh geoip >/dev/null 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "openclash"))
end

o = s:taboption("geo_update", Flag, "geosite_auto_update", font_red..bold_on..translate("Auto Update GeoSite")..bold_off..font_off)
o.default = 0

o = s:taboption("geo_update", ListValue, "geosite_update_week_time", translate("Update Time (Every Week)"))
o:value("*", translate("Every Day"))
o:value("1", translate("Every Monday"))
o:value("2", translate("Every Tuesday"))
o:value("3", translate("Every Wednesday"))
o:value("4", translate("Every Thursday"))
o:value("5", translate("Every Friday"))
o:value("6", translate("Every Saturday"))
o:value("0", translate("Every Sunday"))
o.default = "1"
o:depends("geosite_auto_update", "1")

o = s:taboption("geo_update", ListValue, "geosite_update_day_time", translate("Update time (every day)"))
for t = 0,23 do
o:value(t, t..":00")
end
o.default = "0"
o:depends("geosite_auto_update", "1")

o = s:taboption("geo_update", Value, "geosite_custom_url")
o.title = translate("Custom GeoSite URL")
o.rmempty = true
o.description = translate("Custom GeoSite Data URL, Click Button Below To Refresh After Edit")
o:value("https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat", translate("Loyalsoldier-testingcf-jsdelivr-Version")..translate("(Default)"))
o:value("https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat", translate("Loyalsoldier-fastly-jsdelivr-Version"))
o:value("https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat", translate("Loyalsoldier-github-Version"))
o.default = "https://testingcf.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
o:depends("geosite_auto_update", "1")

o = s:taboption("geo_update", Button, translate("GEOSITE Update")) 
o.title = translate("Update GeoSite Database")
o.description = translate("Current Version:").." "..font_green..bold_on..fs.get_resourse_mtime("/etc/openclash/GeoSite.dat")..bold_off..font_off
o.inputtitle = translate("Check And Update")
o.inputstyle = "reload"
o.write = function()
	m.uci:set("openclash", "config", "enable", 1)
	m.uci:commit("openclash")
	SYS.call("/usr/share/openclash/openclash_geo.sh geosite >/dev/null 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "openclash"))
end

o = s:taboption("geo_update", Flag, "geoasn_auto_update", font_red..bold_on..translate("Auto Update Geo ASN")..bold_off..font_off)
o.default = 0

o = s:taboption("geo_update", ListValue, "geoasn_update_week_time", translate("Update Time (Every Week)"))
o:value("*", translate("Every Day"))
o:value("1", translate("Every Monday"))
o:value("2", translate("Every Tuesday"))
o:value("3", translate("Every Wednesday"))
o:value("4", translate("Every Thursday"))
o:value("5", translate("Every Friday"))
o:value("6", translate("Every Saturday"))
o:value("0", translate("Every Sunday"))
o.default = "1"
o:depends("geoasn_auto_update", "1")

o = s:taboption("geo_update", ListValue, "geoasn_update_day_time", translate("Update time (every day)"))
for t = 0,23 do
o:value(t, t..":00")
end
o.default = "0"
o:depends("geoasn_auto_update", "1")

o = s:taboption("geo_update", Value, "geoasn_custom_url")
o.title = translate("Custom Geo ASN URL")
o.rmempty = true
o.description = translate("Custom Geo ASN Data URL, Click Button Below To Refresh After Edit")
o:value("https://testingcf.jsdelivr.net/gh/xishang0128/geoip@release/GeoLite2-ASN.mmdb", translate("xishang0128-testingcf-jsdelivr-Version")..translate("(Default)"))
o:value("https://fastly.jsdelivr.net/gh/xishang0128/geoip@release/GeoLite2-ASN.mmdb", translate("xishang0128-fastly-jsdelivr-Version"))
o:value("https://github.com/xishang0128/geoip/releases/latest/download/GeoLite2-ASN.mmdb", translate("xishang0128-github-Version"))
o.default = "https://testingcf.jsdelivr.net/gh/xishang0128/geoip@release/GeoLite2-ASN.mmdb"
o:depends("geoasn_auto_update", "1")

o = s:taboption("geo_update", Button, translate("ASN Update")) 	
o.title = translate("Update Geo ASN Database")
o.description = translate("Current Version:").." "..font_green..bold_on..fs.get_resourse_mtime("/etc/openclash/ASN.mmdb")..bold_off..font_off
o.inputtitle = translate("Check And Update")
o.inputstyle = "reload"
o.write = function()
	m.uci:set("openclash", "config", "enable", 1)
	m.uci:commit("openclash")
	SYS.call("/usr/share/openclash/openclash_geo.sh geoasn >/dev/null 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "openclash"))
end

o = s:taboption("chnr_update", Flag, "chnr_auto_update", translate("Auto Update"))
o.description = translate("Auto Update Chnroute Lists")
o.default = 0

o = s:taboption("chnr_update", ListValue, "chnr_update_week_time", translate("Update Time (Every Week)"))
o:value("*", translate("Every Day"))
o:value("1", translate("Every Monday"))
o:value("2", translate("Every Tuesday"))
o:value("3", translate("Every Wednesday"))
o:value("4", translate("Every Thursday"))
o:value("5", translate("Every Friday"))
o:value("6", translate("Every Saturday"))
o:value("0", translate("Every Sunday"))
o.default = "1"

o = s:taboption("chnr_update", ListValue, "chnr_update_day_time", translate("Update time (every day)"))
for t = 0,23 do
o:value(t, t..":00")
end
o.default = "0"

o = s:taboption("chnr_update", Value, "chnr_custom_url")
o.title = translate("Custom Chnroute Lists URL")
o.rmempty = false
o.description = translate("Custom Chnroute Lists URL, Click Button Below To Refresh After Edit")
o:value("https://ispip.clang.cn/all_cn.txt", translate("Clang-CN")..translate("(Default)"))
o:value("https://ispip.clang.cn/all_cn_cidr.txt", translate("Clang-CN-CIDR"))
o:value("https://fastly.jsdelivr.net/gh/Hackl0us/GeoIP2-CN@release/CN-ip-cidr.txt", translate("Hackl0us-CN-CIDR-fastly-jsdelivr"))
o:value("https://testingcf.jsdelivr.net/gh/Hackl0us/GeoIP2-CN@release/CN-ip-cidr.txt", translate("Hackl0us-CN-CIDR-testingcf-jsdelivr"))
o:value("https://raw.githubusercontent.com/gaoyifan/china-operator-ip/refs/heads/ip-lists/china.txt", translate("gaoyifan-github-Version"))
o.default = "https://ispip.clang.cn/all_cn.txt"

o = s:taboption("chnr_update", Button, translate("Chnroute Lists Update")) 
o.title = translate("Update Chnroute Lists")
o.description = translate("Current Version:").." "..font_green..bold_on.. "IPv4 ("..fs.get_resourse_mtime("/etc/openclash/china_ip_route.ipset")..")"..bold_off..font_off
o.inputtitle = translate("Check And Update")
o.inputstyle = "reload"
o.write = function()
	m.uci:set("openclash", "config", "enable", 1)
	m.uci:commit("openclash")
	SYS.call("/usr/share/openclash/openclash_chnroute.sh >/dev/null 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "openclash"))
end

o = s:taboption("auto_restart", Flag, "auto_restart", translate("Auto Restart"))
o.description = translate("Auto Restart OpenClash")
o.default = 0

o = s:taboption("auto_restart", ListValue, "auto_restart_week_time", translate("Restart Time (Every Week)"))
o:value("*", translate("Every Day"))
o:value("1", translate("Every Monday"))
o:value("2", translate("Every Tuesday"))
o:value("3", translate("Every Wednesday"))
o:value("4", translate("Every Thursday"))
o:value("5", translate("Every Friday"))
o:value("6", translate("Every Saturday"))
o:value("0", translate("Every Sunday"))
o.default = "1"

o = s:taboption("auto_restart", ListValue, "auto_restart_day_time", translate("Restart time (every day)"))
for t = 0,23 do
o:value(t, t..":00")
end
o.default = "0"

---- Dashboard Settings
local cn_port=SYS.exec("uci get openclash.config.cn_port 2>/dev/null |tr -d '\n'")
o = s:taboption("dashboard", Value, "cn_port")
o.title = translate("Dashboard Port")
o.default = "9090"
o.datatype = "port"
o.rmempty = false
o.description = translate("Dashboard Address Example:").." "..font_green..bold_on..lan_ip..':'..cn_port..'/ui/yacd'..'、'..lan_ip..':'..cn_port..'/ui/dashboard'..bold_off..font_off

o = s:taboption("dashboard", Value, "dashboard_password")
o.title = translate("Dashboard Secret")
o.rmempty = true
o.description = translate("Set Dashboard Secret")

o = s:taboption("dashboard", Value, "dashboard_forward_domain")
o.title = translate("Public Dashboard Address")
o.datatype = "or(host, string)"
o.placeholder = "example.com"
o.rmempty = true
o.description = translate("Domain Name For Dashboard Login From Public Network")

o = s:taboption("dashboard", Value, "dashboard_forward_port")
o.title = translate("Public Dashboard Port")
o.datatype = "port"
o.rmempty = true
o.description = translate("Port For Dashboard Login From Public Network")

o = s:taboption("dashboard", Flag, "dashboard_forward_ssl")
o.title = translate("Public Dashboard SSL enabled")
o.default = 0
o.description = translate("Is SSL enabled For Dashboard Login From Public Network")

o = s:taboption("dashboard", DummyValue, "Dashboard", translate("Switch(Update) Dashboard Version"))
o.template="openclash/switch_dashboard"
o.rawhtml = true

o = s:taboption("dashboard", DummyValue, "Yacd", translate("Switch(Update) Yacd Version"))
o.template="openclash/switch_dashboard"
o.rawhtml = true

---- version update
version_update_panel = s:taboption("version_update", DummyValue, "", nil)
version_update_panel.template = "openclash/update"
version_update_panel.version_tab = true

---- debug
o = s:taboption("debug", DummyValue, "", nil)
o.template = "openclash/debug"

local t = {
	{Commit, Apply}
}

local CORE_VERSION = HTTP.formvalue("CORE_VERSION")
local RELEASE_BRANCH = HTTP.formvalue("RELEASE_BRANCH")

a = m:section(Table, t)

o = a:option(Button, "Commit", " ")
o.inputtitle = translate("Commit Settings")
o.inputstyle = "apply"
o.write = function()
	m.uci:set("openclash", "config", "smart_enable", "0")
	m.uci:set("openclash", "config", "ipv6_enable", "0")
	m.uci:set("openclash", "config", "ipv6_dns", "0")
	m.uci:set("openclash", "config", "ipv6_mode", "0")
	if CORE_VERSION and RELEASE_BRANCH then
		m.uci:set("openclash", "config", "core_version", CORE_VERSION)
		m.uci:set("openclash", "config", "release_branch", RELEASE_BRANCH)
	end
	m.uci:commit("openclash")
end

o = a:option(Button, "Apply", " ")
o.inputtitle = translate("Apply Settings")
o.inputstyle = "apply"
o.write = function()
	m.uci:set("openclash", "config", "smart_enable", "0")
	m.uci:set("openclash", "config", "ipv6_enable", "0")
	m.uci:set("openclash", "config", "ipv6_dns", "0")
	m.uci:set("openclash", "config", "ipv6_mode", "0")
	if CORE_VERSION and RELEASE_BRANCH then
		m.uci:set("openclash", "config", "core_version", CORE_VERSION)
		m.uci:set("openclash", "config", "release_branch", RELEASE_BRANCH)
	end
	m.uci:set("openclash", "config", "enable", 1)
	m.uci:commit("openclash")
	SYS.call("/etc/init.d/openclash restart >/dev/null 2>&1 &")
	HTTP.redirect(DISP.build_url("admin", "services", "openclash"))
end

m:append(Template("openclash/toolbar_show"))

return m
