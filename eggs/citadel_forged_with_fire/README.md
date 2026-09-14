# Citadel: Forged With Fire

## [Steam](https://store.steampowered.com/app/487120/Citadel_Forged_With_Fire/)

Citadel: Forged With Fire is a massive online sandbox RPG set in the mystical world of Ignus.
Featuring magic, spellcasting, building, exploring and crafting as you fight to make a name for yourself and achieve notoriety across the land.

The dedicated server tool is Steam app `489650`, and unlike most Unreal Engine survival servers it ships a native Linux build, so no Wine or Proton is involved.
The last build is from March 2021.

## Installation/System Requirements

|  | Bare Minimum | Recommended |
|---------|---------|---------|
| Processor | *AMD64 only* | *4 cores* |
| RAM | *6 GiB* | *8 GiB* |
| Storage | *4 GiB* | *6 GiB* |
| Network | *-* | *-* |
| Game Ownership | *Not needed* | *-* |

## Server Ports

| Port  | Default |
|-------|---------|
| Game  | 7777    |
| Query | 27015   |

Both are UDP and both need their own allocation.
They cannot be the same number, or the server fails to bind the second one.

## Configuration

Both ini files live in `Config/` at the root of the server, which the install script symlinks into place as `Citadel/Saved/Config/LinuxServer`.
The engine rewrites that directory on every boot, so keeping the real files at the root is what stops them from being replaced.

| File | Holds |
|---|---|
| `Config/Engine.ini` | `[URL] Port`, the port the server binds |
| `Config/Game.ini` | `[UWorks]` ports, the admin password, and the world settings |

The panel owns three values and writes them into those files on every boot: the game port, the query port, and the admin password.
Edit anything else by hand in `Config/Game.ini`.

`WorldCreationSettings` is one long line holding the server name, the join password, PVP or PVE, the player cap and every gameplay multiplier.
The install seeds it from the Server Name, Server Password, Server Type and Max Players variables, and it is yours after that.
Changing those variables later does not rewrite the line, which is deliberate: rewriting it would throw away any multiplier you had tuned.

Values below 1 have to be written as floating point with a leading zero, so `0.5` rather than `.5`.

Saves land in `Citadel/Saved/SaveGames`, one directory per SteamID64.

## Notes

The UWorks plugin loads its own copy of `steamclient.so` from `Citadel/Plugins/UWorks/Source/ThirdParty/Linux`.
The install script puts it there; without it the server starts but never registers with Steam and never appears in the browser.

The console reports startup with `Steam Server initialized and registered with UWorks`, which is what the panel watches for.
