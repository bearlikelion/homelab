# Holdfast: Nations At War

## [Steam](https://store.steampowered.com/app/589290/Holdfast_Nations_At_War/)

Holdfast: Nations At War is a multiplayer first and third person shooter set during the Napoleonic Wars, with line battles, naval combat and siege modes.

The dedicated server is Steam app `1424230`, a native Linux Unity build that installs under an anonymous login.
The game itself is app `589290` and nobody has to own it to run a server.

This egg replaces the [upstream one](https://github.com/pelican-eggs/games-steamcmd/blob/main/holdfast/egg-holdfast-na-w.json).
That one installs the game into a `holdfastnaw-dedicated/` subdirectory, which breaks in two ways: the Unity engine resolves a relative `-logFile` path against the executable's directory rather than the working directory, so the log lands in `holdfastnaw-dedicated/holdfastnaw-dedicated/logs_output/`, and the image's own auto update installs to `/home/container`, so an update drops a second copy of the game at the root.
This egg installs to `/home/container` instead, which is where the game expects to be and where auto update puts it.

## Installation/System Requirements

|  | Bare Minimum | Recommended |
|---------|---------|---------|
| Processor | *AMD64 only* | *4 cores* |
| RAM | *4 GiB* | *6 GiB* |
| Storage | *12 GiB* | *16 GiB* |
| Network | *-* | *-* |
| Game Ownership | *Not needed* | *-* |

The install is a 2.1 GiB download that unpacks to 10.2 GiB, so a disk limit under 12 GiB fails partway through and leaves a server with no game files.

## Server Ports

| Port  | Default |
|-------|---------|
| Game  | 20100   |
| Query | 27000   |

Both are UDP and both need their own allocation.
The query port is what puts the server in the browser and reports the name, map and player count; without it the server runs but nothing finds it.

Neither port is set on the command line.
`-p` exists but the config file wins, so the panel writes both `server_port` and `steam_query_port` into the chosen config on every boot: the game port from the allocation, the query port from the Query Port variable.
Set that variable to a second allocation you actually hold, or two servers will end up fighting over one query port.

## Configuration

The game ships `serverconfig_default.txt` and `serverconfig_frontlines_default.txt` at the root and overwrites both on every update, which is why nothing here reads them.
The configs the server actually loads live in `configs/`, seeded on install from [`eggs/holdfast_naw/configs/`](configs) in this repository and left alone by updates.

Pick one with the Config File variable, by file name, including the `.txt`.

| Config | Holds |
|---|---|
| `serverconfig_default.txt` | The stock army battlefield rotation |
| `serverconfig_frontlines_default.txt` | The stock frontlines rotation |
| `serverconfig_aly.txt` | Naval and army rotation, map voting on |
| `serverconfig_empire.txt` | Empire rotation |
| `serverconfig_odlaw.txt` | Small melee and line battle rotation |
| `serverconfig_zombies.txt` | The Halloween zombie siege event, with workshop maps |
| `StarWarsEvent.txt` | The Star Wars event, with around thirty workshop maps |

Four lines in whichever file is chosen belong to the panel and are rewritten on every boot:

| Line | Comes from |
|---|---|
| `server_port` | The server's allocation |
| `steam_query_port` | The Query Port variable |
| `server_admin_password` | The Admin Password variable |
| `server_password` | The Server Password variable, blank for a public server |

Everything else in the file is yours.
Edit it in the panel's file manager, or edit the copy in this repository and reinstall.
The install only writes a config that is not already there, so a reinstall keeps whatever you changed in the panel.

Because those four lines are panel owned, the copies in this repository carry no real passwords.
`server_admin_password` reads `CHANGEME` and `server_password` is blank in all of them, which is what the panel overwrites at boot.
Set the real ones per server in the panel.

Adding a config means dropping the file in `configs/` in this repository, adding its name to the list in the install script, and either reinstalling or uploading it directly.

## Console and logs

The Unity log goes to `logs_output/output_<config>` and the startup command tails it, so the console shows the game rather than nothing at all.
Chat, admin actions, player logins, scoreboards and VAC each get their own file under the matching `logs_*` directory.
All of them are archived into `logs_archive/` with a timestamp when the server stops cleanly, which is what the `^C` stop command does.

The panel treats `Finished loading map` as the point the server is up.

## Notes

The Steam API loads `steamclient.so` by absolute path from `~/.steam/sdk64/`.
The install script copies it there out of SteamCMD; without it the server starts, plays fine on a direct connect, and never appears in the browser.

`-framerate` is obsolete and the server says so on every boot.
Tick rate is `network_broadcast_mode` in the config file instead, and its accepted values have moved too.
`Balanced`, which `serverconfig_zombies.txt` still asks for, now logs `[OBSOLETE] network_broadcast_mode Balanced - Defaulting to Standard`.

Map names go stale between patches.
`SnowyPlains` in the stock config is already gone and the server falls back to `FausbergForest`, logging `[OBSOLETE] map_name ... has been removed or renamed`.
That line is worth grepping for after a game update.

Workshop maps listed with `mods_installed` are downloaded by the server itself into `workshop/`, so the first boot after adding one is slower and the console reports what it fetched.

SteamCMD exits 0 even when it downloads nothing, which is how the upstream egg produces a server that installs successfully and then dies with `No such file or directory` and exit code 127.
The install script here retries three times and fails loudly if the binary is still missing, so a bad install looks like a bad install.

Do not add `"create_file": false` to the configuration parser.
Wings opens the file read only when that is set, so every rewrite fails with `truncate configs/...: invalid argument` and the server silently boots on whatever ports the config already held.
