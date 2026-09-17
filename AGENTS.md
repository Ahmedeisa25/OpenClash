# AGENTS.md

## Cursor Cloud specific instructions

This repository is **`luci-app-openclash`**, a LuCI (OpenWrt) web application that
manages the Mihomo/Clash proxy client on a router. It is an OpenWrt *package*, not a
standalone server — there is no `dev server` to run. The development loop is:
edit Lua / shell / JS / `.po` sources → build the helper tools → build the installable
`.ipk`/`.apk` package (which is then flashed onto an OpenWrt device).

### Layout
- `luci-app-openclash/luasrc/` — LuCI Lua controllers/models/views (the web UI logic).
- `luci-app-openclash/root/` — files installed onto the router (`etc/init.d/openclash`,
  config, shell scripts under `usr/share/openclash`, web assets under `www/`).
- `luci-app-openclash/po/{zh-cn,es}/` — gettext translation sources compiled to `.lmo`.
- `luci-app-openclash/tools/po2lmo/` — small C tool that compiles `.po` → `.lmo`.
- `luci-app-openclash/tools/codemirror/` — the CodeMirror 6 config-editor bundle
  (built with esbuild into `root/www/.../js/cm6.min.js`).
- `luci-app-openclash/Makefile` — the OpenWrt package Makefile (`PKG_VERSION`, deps, install rules).

### Toolchain bootstrap (system packages NOT in the base image)
The base image already has `gcc`, `make`, `node`, `npm`, `python3`. The following extra
system tools are needed for **linting** and the **full package build**. They are
intentionally NOT in the startup update script (to keep pod startup reliable); install
them on demand in a session:

```bash
sudo apt-get update
sudo apt-get install -y shellcheck lua5.1 luarocks liblua5.1-0-dev ruby gawk rsync
sudo luarocks install luacheck   # provides `luacheck` (Lua linter)
```
`gawk` + `rsync` are only required for the OpenWrt SDK package build (its prereq check
fails without GNU awk / rsync).

### Dependency refresh (handled by the startup update script)
The only in-repo dependency that needs installing is the CodeMirror build's npm deps:
`npm install --prefix luci-app-openclash/tools/codemirror`. The startup update script
does this automatically (guarded on the presence of the `package.json`).

### Build / lint / run commands
- **po2lmo (translation compiler):**
  `make -C luci-app-openclash/tools/po2lmo` then `sudo make -C luci-app-openclash/tools/po2lmo install`
  (installs `po2lmo` to `/usr/bin`, which the package build needs on `PATH`).
  Compile a translation: `po2lmo luci-app-openclash/po/zh-cn/openclash.zh-cn.po out.lmo`.
- **CodeMirror bundle (config editor UI):** from `luci-app-openclash/tools/codemirror/`:
  `npx esbuild entry.js --bundle --format=iife --global-name=CM6 --minify --target=es2019 --outfile=../../root/www/luci-static/resources/openclash/js/cm6.min.js --legal-comments=none --loader:.css=text`
  (see `.github/workflows/compile_new_ipk.yml` for the full JS/CSS minify pipeline).
  Do NOT upgrade the pinned `@codemirror/*` versions — see the note in `tools/codemirror/package.json`.
- **Lint:** `luacheck luci-app-openclash/luasrc` and
  `shellcheck luci-app-openclash/root/etc/init.d/openclash` (and other `root/**/*.sh`).
  NOTE: luacheck reports thousands of pre-existing warnings (LuCI injects runtime globals
  like `m`, `translate`, `luci.*`) — these are expected, not build failures. Do not treat
  the existing warning/error counts as regressions.
- **Full application package (`.ipk`):** build with the OpenWrt SDK, mirroring
  `.github/workflows/compile_new_ipk.yml`:
  1. Download & extract the x86/64 22.03 SDK
     (`https://downloads.openwrt.org/releases/22.03.0/targets/x86/64/openwrt-sdk-22.03.0-x86-64_gcc-11.2.0_musl.Linux-x86_64.tar.xz`).
  2. `make -C tools/po2lmo && sudo make -C tools/po2lmo install` (po2lmo must be on PATH).
  3. Copy `luci-app-openclash/` into `<SDK>/package/luci-app-openclash/`.
  4. `make defconfig` then `make package/luci-app-openclash/compile V=99`.
  5. Output: `<SDK>/bin/packages/x86_64/base/luci-app-openclash_<version>_all.ipk`.
  The `curl/ca-bundle/ruby/...` "dependency does not exist" warnings during `defconfig`
  are expected in a bare SDK (those come from feeds not installed) and do not block the
  build because the package is `PKGARCH:=all` and those are runtime deps.

### Running the app
The compiled `.ipk` runs only on an OpenWrt system (it drives dnsmasq, iptables/nftables,
TUN, and the Mihomo/Clash core). There is no way to run the live LuCI UI in this VM
without an OpenWrt install; the package build + lint are the local dev verification.
See `.github/skills/openclash-user-guide/SKILL.md` for deep runtime/architecture details.
