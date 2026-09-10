# BORROW THE STORM — Studio Setup

This repository is the **source of truth** for the game. Roblox Studio is the *viewer*.
You sync the repo into Studio with Rojo; you do not hand-edit code inside Studio.

---

## 1. Install the Rojo Studio plugin

Pick either route:

**A. From inside Studio (easiest)**
1. Studio → **Plugins** tab → **Plugins Marketplace**
2. Search **Rojo**, install the one by *Rojo Contributors* (rojo-rbx)
3. A **ROJO** tab appears in the Studio ribbon

**B. From the CLI (after step 2 below)**
```
rojo plugin install
```
This drops the plugin straight into your local Studio plugins folder. Restart Studio.

---

## 2. Install the Rojo CLI

**Recommended — Rokit** (manages every tool this repo uses, pinned to exact versions):

Windows (PowerShell):
```powershell
winget install Rokit.Rokit
```
macOS / Linux:
```bash
curl -fsSL https://github.com/rojo-rbx/rokit/releases/latest/download/rokit-installer.sh | bash
```

Then, from the repository root:
```bash
rokit install
```
That reads `rokit.toml` and installs `rojo`, `stylua` and `selene` at the pinned versions.

**Alternatives**

| Method | Command |
|---|---|
| winget (Windows) | `winget install Rojo.Rojo` |
| Homebrew (macOS) | `brew install rojo` |
| Cargo | `cargo install rojo` |
| Aftman | `aftman install` (reads `aftman.toml`) |
| Manual | Download from https://github.com/rojo-rbx/rojo/releases and put the binary on your PATH |

Verify:
```bash
rojo --version    # expect 7.5.1
```

---

## 3. Connect

From the repository root:

```bash
rojo serve
```

You'll see:
```
Rojo server listening on port 34872
```

In Studio: **ROJO** tab → **Connect** → confirm `localhost:34872`.

The tree appears immediately:

```
ReplicatedStorage/BTS/            <- shared config, core utilities, network schema
ServerScriptService/BTSServer/    <- all authoritative gameplay services
StarterPlayer/StarterPlayerScripts/BTSClient/   <- controllers, UI, effects
```

Leave `rojo serve` running while you work: every file you save on disk is live-patched
into the open Studio session.

---

## 4. First run

1. Press **Play** in Studio.
2. The server bootstrap builds the world procedurally on first heartbeat (see
   `src/Server/World/`), so the place file itself stays tiny and diffable.
3. Watch the Output window — the bootstrap prints a startup report listing every
   service that came online and how long world generation took.

> **Note on the existing place.** Rojo only owns the branches named in
> `default.project.json` (`ReplicatedStorage/BTS`, `ServerScriptService/BTSServer`,
> `StarterPlayerScripts/BTSClient`, plus a handful of service properties). Every
> `$ignoreUnknownInstances: true` marker means Rojo will leave anything else in your
> place alone. Existing models, terrain and scripts outside those branches are not
> touched.

---

## 5. Building a place file without Studio

```bash
rojo build --output BorrowTheStorm.rbxl
```
Useful for CI and for handing a self-contained place to a tester.

---

## 6. Running the test suite

The repository ships a Luau test harness with a Roblox API mock, so gameplay math,
progression, loot, persistence and validation run headlessly:

```bash
./tools/test.sh
```

Requires the `luau` CLI (https://github.com/luau-lang/luau/releases). The script
regenerates the module manifest and runs every spec under `tests/unit/`.
