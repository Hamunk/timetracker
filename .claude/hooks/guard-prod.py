#!/usr/bin/env python3
"""Refuses any tool call that could reach the real TimeTracker install.

The scratch install is isolated by four environment variables, and that
isolation is only as good as the discipline of always setting them. This
removes the discipline from the equation: the harness runs this before every
Bash, Write and Edit, and a command that would touch ~/.timetrack or
~/Applications/TimeTracker does not run at all.

It is deliberately not a linter for good behaviour. It knows three things:

  * the installers may only be reached through ./dev.sh, which sets all four
  * the runtime scripts may only run dev-scoped
  * nothing may write to, or signal, the real install

Everything else is allowed, reads of the real data included — looking at the
log is how half these tasks get understood.

Exit 2 blocks the call and shows the reason.
"""
import json
import os
import re
import shlex
import sys

HOME = os.path.expanduser("~")
PROD_DATA = os.path.join(HOME, ".timetrack")
PROD_APPS = os.path.join(HOME, "Applications", "TimeTracker")

# Reached only through ./dev.sh: they take four variables, and three of the
# four are easy to forget in a way that is invisible until a permission grant
# has already moved.
INSTALLERS = ("install.sh", "uninstall.sh", "sync-apps.sh")

# Run the real install's copy of any of these and it acts on the real log.
RUNTIME = ("action.sh", "start.sh", "toggle.sh", "newcat.sh", "settings.sh",
           "pomodoro-watch.sh", "paint-calendar.sh", "spotify.sh",
           "pause-media.sh", "notify.sh", "prompt.sh",
           "dashboard.py", "migrate_v2.py",
           "ttprompt", "ttpaint", "ttremind")

# Commands that change what they are pointed at. Every argument is a target,
# so naming the real install anywhere in one is enough.
MUTATORS = {"rm", "tee", "truncate", "chmod", "chown", "ln", "mkdir", "touch",
            "dd", "shred", "unlink", "rmdir"}

# ...except these, where only the last argument is written and the earlier
# ones are read. `cp ~/.timetrack/sessions.tsv /tmp/x` copies the real log
# somewhere harmless, and refusing it would refuse an ordinary way of looking
# at the data.
MUTATORS_DEST_LAST = {"cp", "mv", "rsync", "install", "ditto"}

# Editing in place: the file named is both read and written.
INPLACE = re.compile(r"(^|\s)-i(\s|$|['\"])")

# The token a redirection points at.
REDIRECT = re.compile(r">>?\s*([^\s;&|>]+)")

# A heredoc body is a payload, not shell. A file being written may say
# anything, the protected paths included — refusing a command because the
# documentation it writes *mentions* the real install would refuse exactly the
# text that explains the rule.
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# ...unless the heredoc feeds an interpreter, in which case the body is code
# after all and gets read like any other.
FED_TO_SHELL = re.compile(r"\b(bash|sh|zsh|python3?|env|eval)\b[^\n]*<<")


def strip_heredocs(command):
    if FED_TO_SHELL.search(command):
        return command
    lines = command.split("\n")
    out, i = [], 0
    while i < len(lines):
        out.append(lines[i])
        delims = [m.group(2) for m in HEREDOC.finditer(lines[i])]
        i += 1
        for delim in delims:
            while i < len(lines) and lines[i].strip() != delim:
                i += 1
            i += 1
    return "\n".join(out)

# Interpreters and wrappers: the guarded name may be their argument.
WRAPPERS = ("sh", "bash", "zsh", "env", "nohup", "exec", "time", "sudo",
            "python3", "python", "/bin/sh", "/bin/bash", "/usr/bin/env",
            "/usr/bin/python3", "open", "/usr/bin/open", "source", ".")


def is_dev_scoped(text):
    """True if the command names the scratch install, or goes via dev.sh."""
    return (".timetrack-dev" in text
            or "TimeTracker-dev" in text
            or re.search(r"(^|[\s;&|(])\.?/?dev\.sh(\s|$)", text) is not None)


def mentions_prod(text):
    """A reference to the real install, not merely to a path that starts alike."""
    for path in (PROD_DATA, PROD_APPS, "~/.timetrack", "$HOME/.timetrack",
                 "~/Applications/TimeTracker", "$HOME/Applications/TimeTracker"):
        for m in re.finditer(re.escape(path), text):
            tail = text[m.end():m.end() + 4]
            if not tail.startswith("-dev"):
                return True
    return False


def writes_to_prod(command):
    """Does anything here write to the real install — as opposed to merely
    naming it?

    The distinction is the whole usefulness of this check. Nearly every command
    worth running while working on a task like this one reads the real data and
    writes somewhere else, and a rule that only asked "does the real install
    appear anywhere, and does any word that changes files appear anywhere" would
    refuse all of them. So each segment is resolved to its command and its
    arguments, and only an argument actually being written counts.
    """
    for segment in re.split(r"\n|;|&&|\|\||\||&", command):
        for match in REDIRECT.finditer(segment):
            if mentions_prod(match.group(1)):
                return True
        try:
            parts = shlex.split(segment)
        except ValueError:                       # unbalanced quotes
            parts = segment.split()
        i = 0
        while i < len(parts) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", parts[i]):
            i += 1
        if i >= len(parts):
            continue
        name = os.path.basename(parts[i])
        args = [p for p in parts[i + 1:] if not p.startswith("-")]
        if name in ("sed", "perl", "ruby") and INPLACE.search(segment):
            targets = args
        elif name in MUTATORS_DEST_LAST:
            targets = args[-1:]
        elif name in MUTATORS:
            targets = args
        else:
            continue
        if any(mentions_prod(t) for t in targets):
            return True
    return False


def command_words(command):
    """The first word of every segment, seen past env assignments and wrappers.

    Splitting this way is what separates running a script from editing one:
    `./spotlight/install.sh` is an invocation, `cat spotlight/install.sh` is
    not, and only the first is worth refusing.
    """
    words = []
    for segment in re.split(r"\n|;|&&|\|\||\||&", command):
        parts = segment.strip().split()
        i = 0
        while i < len(parts):
            part = parts[i]
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", part):      # FOO=bar
                i += 1
                continue
            if os.path.basename(part) in WRAPPERS or part in WRAPPERS:
                i += 1
                noexec = False
                # Skip the interpreter's own flags, and notice `-n`: `bash -n
                # install.sh` parses the file and runs none of it, which is
                # how the installers get checked without being run.
                while i < len(parts) and parts[i].startswith("-"):
                    if "n" in parts[i][1:] and not parts[i].startswith("--"):
                        noexec = True
                    i += 1
                if noexec:
                    break
                continue
            words.append(part)
            break
    return words


def check_bash(command):
    command = strip_heredocs(command)
    words = command_words(command)
    dev = is_dev_scoped(command)

    for word in words:
        base = os.path.basename(word.strip("\"'"))
        if base in INSTALLERS:
            return (
                "Blocked: %s must be reached through ./dev.sh, which sets all "
                "four isolation variables (TIMETRACK_DIR, TIMETRACK_APPS_DIR, "
                "TIMETRACK_BID_PREFIX, TIMETRACK_VERB). Setting only the first "
                "two still gives the scratch bundles the real install's bundle "
                "identifiers, and macOS hands TCC grants out by identifier.\n"
                "Use:  ./dev.sh install   |   ./dev.sh remove" % base)
        if base in RUNTIME and not dev:
            return (
                "Blocked: %s would run against the real install and write to "
                "the real log. Run it dev-scoped instead:\n"
                '  eval "$(./dev.sh env)" && "$HOME/.timetrack-dev/bin/%s"'
                % (base, base))

    if re.search(r"(^|\s)(pkill|killall)\s", command) and not dev:
        if any(n in command for n in
               ("ttprompt", "pomodoro-watch", "spotify.sh", "dashboard.py",
                "pause-media", "timetrack", "TimeTracker")):
            return (
                "Blocked: an unscoped pkill/killall is exactly what ends a "
                "live pomodoro. Match this install's own paths, or kill by the "
                "pid in ~/.timetrack-dev/.tomato-overlay.pid.")

    if writes_to_prod(command):
        return (
            "Blocked: this would write to the real install. Reading it is "
            "fine — cat, grep, ls, head all pass — but changes belong in "
            "~/.timetrack-dev, via ./dev.sh.")
    return None


def check_path(path):
    if not path:
        return None
    resolved = os.path.abspath(os.path.expanduser(path))
    for prod in (PROD_DATA, PROD_APPS):
        if resolved == prod or resolved.startswith(prod + os.sep):
            return ("Blocked: %s is inside the real install. Edit the repo, "
                    "then ./dev.sh install to try the change out." % path)
    return None


def main():
    raw = sys.stdin.read()
    try:
        event = json.loads(raw)
        tool = event.get("tool_name", "")
        data = event.get("tool_input", {}) or {}
        if tool == "Bash":
            reason = check_bash(data.get("command", "") or "")
        else:
            reason = check_path(data.get("file_path", "") or "")
    except Exception as exc:
        # A broken guard must not block ordinary work, but it must not wave
        # through the very calls it exists to catch either.
        if ".timetrack" in raw or "install.sh" in raw:
            sys.stderr.write("Blocked: the production guard failed to parse "
                             "this call (%s), and it names the real install.\n"
                             % exc)
            return 2
        return 0
    if reason:
        sys.stderr.write(reason + "\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
