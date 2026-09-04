# spawn-claude

**Claude-Code-Sessions im Hintergrund starten — und sie lesen, steuern und beenden.**

[English](README.md) · [Deutsch](README.de.md)

---

Ein [Claude Code](https://claude.com/claude-code)-Plugin für paralleles Arbeiten. Du
startest eine benannte Session in einem abgekoppelten Terminal, lässt sie arbeiten und
schaust hinein, wann immer du willst:

```
/spawn refactor-auth "refactore das Auth-Modul und zieh die Tests nach"
/spawn read refactor-auth
/spawn tell refactor-auth "denk auch an den Fall abgelaufener Token"
```

## Warum

Bei manchen Aufgaben muss niemand zusehen. Ein langes Refactoring, eine Testsuite, die
wieder grün werden soll, drei unabhängige Bugs — jedes davon kann in einer eigenen Session
laufen, während du etwas anderes machst.

Der Haken ist sonst, dass eine Hintergrund-Session zur Blackbox wird. Hier nicht: Eine
gestartete Session ist adressierbar — du siehst ihren Bildschirm, schickst ihr eine
Anschlussanweisung, wartest auf sie und fährst sie herunter.

## Installation

```
/plugin marketplace add PascalKremp/spawn-claude
/plugin install spawn-claude
```

## Voraussetzungen

**tmux** (`brew install tmux` / `sudo apt install tmux`) — das ist der portable Weg, er
funktioniert auch ohne GUI und über SSH. Unter macOS mit iTerm2 oder innerhalb von
[cmux](https://cmux.io) werden automatisch diese verwendet.

## Backends

|  | cmux | iTerm2 | tmux |
|---|---|---|---|
| Wird gewählt, wenn | du in cmux bist | macOS + iTerm2 installiert | tmux im `PATH` |
| Erzeugt | unfokussierten Workspace | neues Fenster | abgekoppelte Session |
| Lesen / steuern / warten / schließen | ✅ | ❌ | ✅ |
| Braucht eine GUI | ja | ja | **nein** |

`auto` probiert sie in dieser Reihenfolge und bricht mit einer klaren Meldung ab, wenn
keines verfügbar ist, statt zu raten. Erzwingen mit `--terminal cmux|iterm|tmux|auto`.

Das iTerm-Backend öffnet ein sichtbares Fenster und ist „abschicken und vergessen" — es
wird nichts Adressierbares gespeichert, die Lifecycle-Befehle gelten dort also nicht.

## Befehle

```bash
spawn.sh <name> [prompt] [cwd]        # starten (Yolo-Modus, Remote Control an)
spawn.sh list                         # laufende Spawns: Ref, Name, Verzeichnis
spawn.sh read  <name> --lines 40      # was macht sie gerade? (--scrollback für mehr)
spawn.sh tell  <name> "<text>"        # Anschlussanweisung schicken
spawn.sh key   <name> escape          # unterbrechen
spawn.sh wait  <name> --timeout 600   # blockieren, bis sie fertig ist
spawn.sh close <name>                 # beenden
```

Optionen: `--resume <id>`, `--continue`, `--fork`, `--model <model>`, `--cwd <dir>`,
`--terminal <backend>`, `--dry-run`.

Sessions starten mit `--dangerously-skip-permissions` — genau das ist der Zweck — starte
sie also nur in Verzeichnissen, denen du vertraust.

## Ein Unterschied, den man kennen sollte

`wait` bedeutet auf den beiden steuerbaren Backends nicht ganz dasselbe:

- **cmux** fragt den per Hook gelieferten Status `claude_code=Idle|Running` ab, `wait`
  heißt dort also *„untätig, bereit für Eingabe"*.
- **tmux** hat kein solches Signal, dort heißt `wait` *„der claude-Prozess ist beendet"* —
  also Fertigstellung. Eine tmux-Session, die an einem Prompt auf dich wartet, gilt hier
  weiterhin als laufend.

Das wird ehrlich so berichtet, statt es mit einem Auslesen des Bildschirms zu fingieren.

## Hinweise

- Gestartete Sessions sind unabhängig: Wenn du die startende Session schließt, ändert das
  nichts an ihnen.
- Vor dem Start wird das Zielverzeichnis in `~/.claude.json` als vertrauenswürdig
  markiert, damit die Session nicht an Claudes „Quick safety check" hängen bleibt.
- tmux-Sessions heißen `spawn-<task>`; verbinden mit `tmux attach -t spawn-<task>`.
- Das Verzeichnis der gestarteten Sessions liegt in
  `~/.local/state/spawn-claude/spawns.tsv`.

## Tests

```bash
bash skills/spawn-claude/tests/run-all.sh
```

278 Prüfungen, darunter ein echter tmux-Durchlauf (spawn/read/tell/wait/close) gegen ein
Stub-`claude`-Binary. Der tmux-Teil überspringt sich selbst, wenn tmux fehlt.

## Lizenz

MIT
