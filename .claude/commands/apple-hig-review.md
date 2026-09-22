---
description: Review the current branch's UI changes against Apple's Human Interface
  Guidelines
---

<!-- markdownlint-disable MD041 -->

Review the macOS UI changes on the current branch with the `apple-hig-reviewer`
agent.

1. Find the changes: `git diff <default branch>...HEAD` limited to the app's
   Swift sources, and read enough surrounding code to understand them.
2. If `AGENTS.md` documents a command that renders the app's screens to images,
   run it, and review the images in light and dark appearance. If it documents none,
   review the source only and say so in the result.
3. Report findings in the format the agent defines, or say plainly that there are
   none and which surfaces were reviewed.

Do not edit any file.