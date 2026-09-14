# Dark and Light

## [Steam](https://store.steampowered.com/app/529180/Dark_and_Light/)

Dark and Light is a survival RPG set in a sprawling world of magic, built by Snail Games on the same Unreal Engine 4 codebase as ARK: Survival Evolved.
Its command line, its config files and its RCON support all behave like ARK's.

The dedicated server tool (Steam app `630230`) ships a Windows build only, so this egg runs it under Proton.
The last build Snail published is from November 2019, so there is nothing for auto update to fetch and no patch is going to break the egg.

## Installation/System Requirements

|  | Bare Minimum | Recommended |
|---------|---------|---------|
| Processor | *AMD64 only* | *4 cores* |
| RAM | *6 GiB* | *8 GiB* |
| Storage | *8 GiB* | *12 GiB* |
| Network | *-* | *-* |
| Game Ownership | *Not needed* | *-* |

## Server Ports

The peer port is not configurable and is always the game port plus one.

| Port  | Default |
|-------|---------|
| Game  | 7777    |
| Peer  | 7778    |
| Query | 27015   |
| RCON  | 27020   |

Give the server an allocation for the game port and a second one for the query port.
RCON only has to answer on `127.0.0.1`, because the panel's stop command is the only thing that uses it.

## Maps

`SERVER_MAP` takes the short map name.

| Name      | Map                 |
|-----------|---------------------|
| `DNL_ALL` | Cape of Sacred Path, the default map |
| `TheShard`| The Shard, the DLC map |

## Configuring the server

The command line covers the server name, both passwords, the player cap and the ports.
Everything else lives in `DNL/Saved/Config/WindowsServer/GameUserSettings.ini`, which the server writes on its first boot.

`DNL/Saved/Config/CleanSourceConfigs/GameUserSettings.ini` lists every setting the game understands.
It is a reference copy, so read it and make the edits in the file above.

## Stopping

The stop command is a SIGINT, which the startup command traps and turns into an RCON `saveworld` followed by `DoExit`.
That is what makes the world save on shutdown, so the admin password has to be set and RCON has to be reachable on loopback.

## Notes

The server only appears in the Steam and in-game browsers when `steamclient64.dll`, `tier0_s64.dll` and `vstdlib_s64.dll` sit next to `DNLServer.exe`.
SteamCMD drops them in the install root, and the install script copies them into `DNL/Binaries/Win64`.

If the server crashes on boot rather than reaching the log, add `-nosteamclient` to Additional Arguments (FLAGS).
It starts without the Steam client libraries at the cost of not being listed in the server browser.
