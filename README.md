<p align="center">
  <img src=".github/banner.png" alt="NorgannonDB Collector: help map Azeroth." width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/WoW%20Forever-1.60.1-e7c66c?style=flat-square" alt="WoW Forever 1.60.1">
  <img src="https://img.shields.io/badge/status-early%20development-6fdc8c?style=flat-square" alt="Status: early development">
  <img src="https://img.shields.io/badge/part%20of-NorgannonDB%20suite-1f3326?style=flat-square" alt="Part of the NorgannonDB suite">
</p>

> [!WARNING]
> **Very much a work in progress.** This is an early build for WoW Forever (client 1.60.1), in
> active development and testing. Expect missing features, rough edges, bugs, and changes that
> break things between versions. Bug reports and feedback are welcome in
> [Issues](../../issues).

**Play as you always do. Every NPC, quest and drop you see makes the database better.**

[NorgannonDB](https://github.com/zmarotrix/NorgannonDB) is the open game database behind
Clairvoyance and Oracle. It started from Questie and pfQuest, but WoW Forever changed spawns,
quests and drops, and some things, like boss drop chances, were never known at all. The Collector
fills those gaps from real play, and everyone who uses the suite benefits.

## Why run it

- **Nothing to do.** It works quietly in the background, with no windows or prompts while you
  play, and it saves its work until after combat so it never slows a fight.
- **Private.** No character names and no other players are ever recorded or exported.
- **Rewarding.** At each login it shows what your last session found, including things
  NorgannonDB had wrong or didn't know.

## Sharing what you found

1. Type **`/ndbc export`**. A window opens with your data on one line, already selected.
2. Press **Ctrl+C**.
3. Paste it into a message or a text file for the NorgannonDB maintainer.

Each export holds everything you've recorded so far, so a fresh one every now and then is all it
takes. By sending your data you let it be included in NorgannonDB, which is published under
GPL-3.0. Exports contain no character names.

## Commands

| Command | What it does |
|---|---|
| `/ndbc export` | open the export window |
| `/ndbc stats` | what you've recorded so far |
| `/ndbc report [type] [n]` | what you found that NorgannonDB has wrong or missing |
| `/ndbc verbose` | announce each new finding in chat |
| `/ndbc pause` | stop or resume collecting |
| `/ndbc corrections on\|off` | apply the merged corrections that ship with the add-on |
| `/ndbc debug [show [n] \| chat \| clear]` | log what it sees and why it skips things (never exported) |
| `/ndbc reset` | delete everything collected |

## Getting started

Download the Collector and **[NorgannonDB](https://github.com/zmarotrix/NorgannonDB)** (on each
page: **Code → Download ZIP**), extract them into your WoW Forever `Interface/AddOns` folder, and
remove the `-main` GitHub adds to each folder's name (`NorgannonDBCollector`, `NorgannonDB`). That's
it: the Collector starts working the next time you log in.

## The NorgannonDB suite

|   | Add-on | |
|:-:|---|---|
| <img src="https://raw.githubusercontent.com/zmarotrix/NorgannonDB_Core/main/.github/suite/clairvoyance.png" width="36"> | **[Clairvoyance](https://github.com/zmarotrix/Clairvoyance)** | Quest helper: your objectives on the map, minimap and compass, and a modern tracker |
| <img src="https://raw.githubusercontent.com/zmarotrix/NorgannonDB_Core/main/.github/suite/oracle.png" width="36"> | **[Oracle](https://github.com/zmarotrix/Oracle)** | Dungeon and zone atlas: maps, bosses, loot, zones and professions |
| <img src="https://raw.githubusercontent.com/zmarotrix/NorgannonDB_Core/main/.github/suite/norgannondb.png" width="36"> | **[NorgannonDB](https://github.com/zmarotrix/NorgannonDB)** | The open game database underneath, with **[NorgannonDB Core](https://github.com/zmarotrix/NorgannonDB_Core)**, the shared runtime |
| <img src="https://raw.githubusercontent.com/zmarotrix/NorgannonDB_Core/main/.github/suite/collector.png" width="36"> | **NorgannonDB Collector** | Help map Azeroth: improves the database while you play |
| <img src="https://raw.githubusercontent.com/zmarotrix/NorgannonDB_Core/main/.github/suite/foresight.png" width="36"> | Foresight | Planner. *Coming later* |
| <img src="https://raw.githubusercontent.com/zmarotrix/NorgannonDB_Core/main/.github/suite/archivum.png" width="36"> | Archivum | Look anything up in game. *Coming later* |

---

## Technical details

<details>
<summary><b>What it records</b> (SavedVariables <code>NorgannonDBCollectorDB</code>, account-wide)</summary>

| Data | Source | Stored as (SPEC.md shapes) |
|---|---|---|
| NPCs: name, level range, rank, subName, position | target / mouseover within ~10 yd, every interaction | `npcs[id].spawns = {[areaId]={{x,y}}}` |
| Objects: position, name | looting / gathering | `objects[id].spawns` |
| Kills and loot | `PARTY_KILL` (or XP message), loot window sources | `obs.kills`, `obs.looted`, `obs.loot[itemId]` → `drops` chances at logout |
| Pickpocket / skinning / container loot | spell cast before the loot window; opened bag item | `obs.pickpocketLoot`, `obs.skinningLoot`, `items[id].obs.loot` |
| Quests: giver, ender, objectives (text, type, required count), rewards | quest dialogs + quest log | `quests[id].starters/finishers/objectives/rewards` |
| Vendors: items and stock | merchant window | `npcs[id].sells`, `items[id].vendors` |
| Services | gossip, merchant, trainer, flight map, bank, AH, stable, innkeeper frames | `npcs[id].flags` (NorgannonDB `npcFlags`) |

Evidence the SPEC has no field for (sighting counts, loot counts, objective text) is kept in
each record's `obs`. Players and pets are never recorded. Nothing is collected in combat
(kills are buffered and counted afterwards) and no positions are taken inside instances (the game
doesn't give them there). Secret values are skipped and no protected function is called.

</details>

<details>
<summary><b>Importing data</b> (maintainer)</summary>

Save the strings players send you in text files. A file can hold any number of them, with other
text around them. Or copy one string and use `--clipboard`:

```bash
python tools/norgannondb/import_collected.py inbox/*.txt --merge
python tools/norgannondb/import_collected.py --clipboard --merge
python tools/norgannondb/import_collected.py "<WoW>/_classic_beta_/WTF/Account/<ACCOUNT>/SavedVariables/NorgannonDBCollector.lua" --merge
```

Each player's data is stored once in `build/collected/submissions/<contributor>.lua`, and a newer
export replaces an older one. `--merge` runs the merge below over all of them and writes
`build/collected/corrections.json` (to review) and `build/collected/Corrections.lua`. Copy the
latter to `addons/NorgannonDBCollector/Corrections.lua` to use the corrections in game.

</details>

<details>
<summary><b>Feeding it back into NorgannonDB</b> (maintainer)</summary>

```bash
python tools/norgannondb/merge_collected.py "<WoW>/_forever_/WTF/Account/<ACCOUNT>/SavedVariables/NorgannonDBCollector.lua" --json build/collected/corrections.json --lua addons/NorgannonDBCollector/Corrections.lua
```

QuestieDB stays the source of truth. A field QuestieDB provides is only changed after
`--min-override` (default 3) observations. Data QuestieDB lacks needs `--min-add` (1). Drop chances
need `--min-kills` (20) sources and a difference beyond 3 standard errors. Candidates below those
thresholds are listed as "held back". The `--lua` output is applied in game through
`NorgannonDB:RegisterCorrection` (provenance `NorgannonDBCollector`). The `--json` output is for
review or a future build step.

</details>

<details>
<summary><b>Licence</b></summary>

The Collector is free to download and use. The source is published for transparency, but all
rights are reserved for now; see [LICENSE](LICENSE). Made by **Maro**.

</details>
