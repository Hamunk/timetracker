# Tomat 🍅

> *Simplicity is prerequisite for reliability.*
> — Edsger W. Dijkstra, EWD498

Track what you work on, and take real breaks. For macOS.

## Install

Open Terminal, paste this line, and press Return:

```bash
git clone https://github.com/Hamunk/timetracker.git && cd timetracker && ./spotlight/install.sh
```

If macOS offers to install the command line developer tools, click Install,
wait for it to finish, and paste the line again. Tomat opens by itself
when it is done and asks what you work on.

## Use

Open **Tomat** like any other app — or type `time` in Spotlight, which finds
it too. Choose a subject to start; press
Stop when you are done. Starting asks for a plan and stopping asks what you
got done; both are optional, and Cancel means nothing happened.

Or, faster, from Spotlight (<kbd>⌘</kbd> <kbd>Space</kbd>):

| Type | Does |
|---|---|
| `tomat` | open the app |
| `time` | stop, or start the last subject |
| `time calculus` | start or switch to a subject, by name, code or keyword |
| `time update` | install the newest version |

With **Pomodoro** ticked, a tomato fills the screen after 25 minutes and
offers a 5-minute break. The break lasts until you say you are back.
<kbd>Tab</kbd> on a break opens a menu with Spotify, a note to Reminders,
and Messages.

**Friends** can see where each other is in the pomodoro and write during
breaks. Add one by their username; they accept. Off until you turn it on.

**Calendar** copies your sessions into a calendar you choose — your main one
is fine. Tomat only ever changes events it added itself, and leaves alone any
of those you move, edit or delete.

## Update

`time update` in Spotlight, or Settings → Check for updates. Your data is
backed up before every update.

## Your data

Everything is in `~/.timetrack`, as text files only you can read:
`sessions.tsv` is the log, `categories.tsv` your subjects, `settings.tsv`
what you changed. Every install and update copies them to
`~/.timetrack/backups` first, and keeps the last ten copies.

Nothing leaves your Mac, except Messages when it is on: encrypted, through a
public relay. [SECURITY.md](SECURITY.md) has the details.

## Remove

From the folder you installed from:

```bash
./spotlight/uninstall.sh
```

Your data stays. Add `--purge-data` to remove it too.

## Releasing

A release is a tag. Users only ever get tagged versions:

```bash
git tag v2.0.0 && git push --tags
```

Bump `VERSION` in the same commit; `time update` refuses a tag whose
`VERSION` says something else.

## Working on it

`./dev.sh` builds a second, separate install (`devtime`, *Tomat
(devtime)*) with its own data and identity, so the program can be changed while
the real one is in use. [CLAUDE.md](CLAUDE.md) describes the arrangement.

Tests: `python3 spotlight/migrate.test.py`, `python3 spotlight/chat.test.py`,
`./spotlight/paintplan.test.sh`, and `python3 .claude/hooks/guard-prod.test.py`.

## License

MIT.
