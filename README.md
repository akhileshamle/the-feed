# the-feed

Three daily prompts (physics 11:15, math 11:25, DSA 14:00 IST) run on your Mac.
Each reads its prompt from the event notes in your `claude-maxing` calendar, asks Claude,
appends the answer to `feed.json`, and pushes. GitHub Pages serves `index.html`.

## One-time setup (in Terminal, from this folder)

    git init -b main && git add -A && git commit -m "init"
    gh repo create the-feed --public --source=. --push        # or create it on github.com and add the remote
    gh api -X POST repos/$(gh api user -q .login)/the-feed/pages -f "source[branch]=main" -f "source[path]=/"

Your page: https://<your-username>.github.io/the-feed/

## Test, then schedule

    bash bin/run-feed.sh physics     # allow the Calendar access prompt; check the page in ~1 min
    bash install.sh                  # installs the three daily jobs

Logs: `logs/run.log`. Remove the jobs: `bash install.sh --uninstall`.

## Notes
- The repo is public: anything Claude writes here is readable by anyone with the URL.
- The Mac must be awake. Missed jobs run when it wakes.
- Edit the event notes in Calendar to change a prompt. Times live in `install.sh`.
