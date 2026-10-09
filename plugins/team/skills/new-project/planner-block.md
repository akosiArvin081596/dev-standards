# Planner setup block (new-project, Part B step 8)

Print the block below in the conversation, with every `<…>` filled in from `.team/new-project.conf` and the provisioning results. **Never write it to a file in the repo:** the header holds the staging and production URLs. After the block, print the contents of `docs/planner-instructions.md` from the clone, so the owner can copy both.

````
PLANNER SETUP for <Project>

1. In claude.ai, create a Claude project named "<Project> planner".

2. Paste this header as the start of its instructions:

   Project: <Project>
   Purpose: <one-line purpose>
   Client: <client name, or "internal">
   Timezone: <IANA name>. Write every time a person reads with the zone, e.g. "3:00 PM <IANA name>".
   Repo: https://github.com/<owner>/<name>
   Staging: https://<staging host> (password-protected; the owner shares the login)
   Production: https://<production host>

   Then paste the full contents of docs/planner-instructions.md below the header.

3. Add project knowledge from GitHub: the repo URL above, with CLAUDE.md, docs/ and
   .github/ISSUE_TEMPLATE/ selected. Press Sync after merges that change them. The
   project's own CLAUDE.md and docs arrive with the skeleton PR, so sync once it merges.

4. Start the first chat with the client's brief.
````

Then remind the owner of these points:
- Issues the planner drafts are created by the owner (on GitHub, or by asking Claude Code in the project), so they're opened under the owner's account and agents will take them.
- The staging login comes from `team-staging-login <name>`, run in their own terminal.
