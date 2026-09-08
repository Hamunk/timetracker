#!/usr/bin/env python3
"""Cases for guard-prod.py. Run: python3 .claude/hooks/guard-prod.test.py

The guard is safety equipment, and safety equipment that has never been tested
is decoration. Both halves matter equally: a guard that misses a dangerous
command fails loudly and once, but a guard that refuses ordinary work fails
quietly and forever, because the way around it is to switch it off.

The cases live in a file rather than in a shell command on purpose — a command
carrying `rm -rf ~/.timetrack` as a test fixture is indistinguishable, to the
guard, from one meaning it.
"""
import json
import os
import subprocess
import sys

GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "guard-prod.py")
HOME = os.path.expanduser("~")

BLOCK = "BLOCK"
ALLOW = "ALLOW"

# (expectation, tool, payload, what it stands for)
CASES = [
    # --- the installers, which take four variables and are easy to under-set
    (BLOCK, "Bash", "./spotlight/install.sh", "installer, direct"),
    (BLOCK, "Bash", "cd spotlight && ./install.sh", "installer, after cd"),
    (BLOCK, "Bash", "bash spotlight/sync-apps.sh", "sync-apps via bash"),
    (BLOCK, "Bash", "./spotlight/uninstall.sh --purge-data", "uninstall --purge-data"),
    (BLOCK, "Bash", "TIMETRACK_DIR=$HOME/.timetrack-dev ./spotlight/install.sh",
     "installer with only one of the four set"),
    (BLOCK, "Bash", "TIMETRACK_DIR=$HOME/.timetrack-dev "
                    "TIMETRACK_APPS_DIR=$HOME/Applications/TimeTracker-dev "
                    "./spotlight/install.sh",
     "installer with two of four: still shares bundle identifiers"),

    # --- the runtime scripts, which act on whichever install they belong to
    (BLOCK, "Bash", "~/.timetrack/bin/action.sh stop", "real action.sh"),
    (BLOCK, "Bash", "$HOME/.timetrack/bin/toggle.sh", "real toggle.sh"),
    (BLOCK, "Bash", "/usr/bin/python3 ~/.timetrack/bin/dashboard.py", "real dashboard"),

    # --- the signals that end a live cycle
    (BLOCK, "Bash", 'pkill -f "ttprompt overlay"', "unscoped pkill of the overlay"),
    (BLOCK, "Bash", "killall ttprompt", "killall by name"),
    (BLOCK, "Bash", "pkill -f pomodoro-watch.sh", "unscoped pkill of the watcher"),

    # --- writes to the real install
    (BLOCK, "Bash", "rm -f ~/.timetrack/state", "rm the real state file"),
    (BLOCK, "Bash", "echo x > $HOME/.timetrack/settings.tsv", "redirect into real data"),
    (BLOCK, "Bash", 'sed -i "" s/a/b/ ~/.timetrack/categories.tsv', "sed -i on real data"),
    (BLOCK, "Bash", "cp /tmp/x ~/Applications/TimeTracker/foo", "cp into the real bundles"),
    (BLOCK, "Write", HOME + "/.timetrack/categories.tsv", "Write into real data"),
    (BLOCK, "Edit", "~/Applications/TimeTracker/time.app/Contents/MacOS/run",
     "Edit a real bundle"),

    # --- a heredoc fed to an interpreter is code, not payload
    (BLOCK, "Bash", "bash <<'EOF'\nrm -rf ~/.timetrack\nEOF", "rm smuggled via bash heredoc"),
    (BLOCK, "Bash", "/bin/sh <<EOF\n./spotlight/install.sh\nEOF",
     "installer smuggled via sh heredoc"),

    # --- the scratch install, which is the whole point
    (ALLOW, "Bash", "./dev.sh install", "dev.sh install"),
    (ALLOW, "Bash", "./dev.sh remove --purge-data", "dev.sh remove"),
    (ALLOW, "Bash", "./dev.sh status", "dev.sh status"),
    (ALLOW, "Bash", '"$HOME/.timetrack-dev/bin/action.sh" start x', "scratch action.sh"),
    (ALLOW, "Bash", "rm -rf ~/.timetrack-dev", "wiping the scratch data"),
    (ALLOW, "Bash", "cat ~/.timetrack-dev/sessions.tsv", "reading the scratch log"),

    # --- reading the real install: allowed, and usually the point
    (ALLOW, "Bash", "cat ~/.timetrack/sessions.tsv | head -20", "read the real log"),
    (ALLOW, "Bash", "grep -c . ~/.timetrack/categories.tsv", "grep the real categories"),
    (ALLOW, "Bash", "ls -la ~/Applications/TimeTracker", "list the real bundles"),
    (ALLOW, "Bash", "wc -l $HOME/.timetrack/sessions.tsv", "count the real log"),

    # --- working on the source, which is inert until installed
    (ALLOW, "Bash", "cat spotlight/install.sh", "read the installer"),
    (ALLOW, "Bash", "bash -n spotlight/install.sh", "syntax-check the installer"),
    (ALLOW, "Bash", "shellcheck spotlight/install.sh", "lint the installer"),
    (ALLOW, "Bash", "grep -n BID_PREFIX spotlight/sync-apps.sh", "grep the installer"),
    (ALLOW, "Bash", "git diff spotlight/install.sh", "diff the installer"),
    (ALLOW, "Write", "spotlight/toggle.sh", "Write repo source"),

    # --- a heredoc body is a payload, even when it names what the guard guards
    (ALLOW, "Bash",
     "cat > CLAUDE.md <<'MDEOF'\n"
     "data lives in ~/.timetrack and you must not rm it\n"
     "never run ./spotlight/install.sh directly\n"
     "MDEOF\nls -la",
     "documentation quoting the rules it documents"),

    # --- reading the real install while writing somewhere else. This is the
    # shape of almost every useful command here, and the reason the write check
    # resolves each segment to a command and its arguments rather than asking
    # whether a dangerous-looking word appears anywhere in the line.
    (ALLOW, "Bash", "mkdir -p /tmp/snap && find ~/.timetrack -type f "
                    "-exec shasum {} \\; > /tmp/snap/before",
     "hash the real data into a scratch file"),
    (ALLOW, "Bash", "cp ~/.timetrack/categories.tsv /tmp/x", "copy real data out"),
    (ALLOW, "Bash", "cp ~/.timetrack/categories.tsv ~/.timetrack-dev/", "seed the scratch"),
    (ALLOW, "Bash", "diff ~/.timetrack/categories.tsv ~/.timetrack-dev/categories.tsv",
     "diff the two installs"),
    (ALLOW, "Bash", "ls ~/Applications/TimeTracker > /tmp/list", "list real bundles to a file"),
    (BLOCK, "Bash", "cp /tmp/x ~/.timetrack/categories.tsv", "copy into the real data"),
    (BLOCK, "Bash", "mkdir -p ~/.timetrack/bin", "mkdir inside the real install"),

    # --- nothing to do with any of this
    (ALLOW, "Bash", "echo hi > /tmp/scratch", "unrelated write"),
    (ALLOW, "Bash", "git status", "unrelated command"),
    (ALLOW, "Bash", "npm test", "unrelated command"),
]


def verdict(tool, payload):
    key = "command" if tool == "Bash" else "file_path"
    event = json.dumps({"tool_name": tool, "tool_input": {key: payload}})
    proc = subprocess.run([sys.executable, GUARD], input=event,
                          capture_output=True, text=True)
    return (BLOCK if proc.returncode == 2 else ALLOW), proc.stderr.strip()


def main():
    failed = 0
    for want, tool, payload, label in CASES:
        got, message = verdict(tool, payload)
        if got == want:
            print("  ok    %-5s  %s" % (got, label))
        else:
            failed += 1
            print("  FAIL  want %s got %s  %s" % (want, got, label))
            if message:
                print("          %s" % message.splitlines()[0])
    print("\n%d cases, %d failed" % (len(CASES), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
