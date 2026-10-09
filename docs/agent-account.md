# Optional: an agent machine account

By default agents act as you on GitHub. The fences (deny rules, ask rules and the `fence` hook) keep them in line, but GitHub itself can't tell an agent from you. An agent machine account moves part of that separation into GitHub: a second account that agents commit, push and call `gh` as. It is **off** until you set it up.

## What GitHub then enforces for you

| Agents can no longer… | Why |
|---|---|
| approve a production deployment | only you are the environment's required reviewer |
| bypass the `main` ruleset or merge a release PR | the bypass belongs to the repository admin role; the agent is a write collaborator |
| create, move or delete `v*` tags | the tag ruleset allows only the admin role |
| add an `owner-approved` that counts | `guarded-paths` accepts the label only when its latest `labeled` event came from the owner login |

The fences stay on as well; this is defence in depth.

## Set it up (once)

1. **Create the account** on github.com (for example `<you>-agent`) with its own email, and turn on 2FA.
2. **SSH key and alias.** In a normal terminal: `ssh-keygen -t ed25519 -f ~/.ssh/id_agent -C "<you>-agent"`. Add `~/.ssh/id_agent.pub` to the agent account (Settings → SSH keys), then add to `~/.ssh/config`:
   ```
   Host github.com-agent
     HostName github.com
     User git
     IdentityFile ~/.ssh/id_agent
     IdentitiesOnly yes
   ```
   Check with `ssh -T git@github.com-agent` (it should greet the agent login).
3. **Log `gh` in as the agent**: `gh auth login --hostname github.com --git-protocol ssh` and choose the agent account. `gh auth login` makes the new account the active one, so afterwards run `gh auth switch -u <your main login>` yourself to restore your usual active account. (The pack itself never runs `gh auth switch`; it picks the account per command with `GH_TOKEN="$(gh auth token -u <login>)"`.)
4. **Tell the pack** by adding one line to `~/.config/team/accounts.conf`:
   ```
   agent|<you>-agent|github.com-agent|<Agent Name>|<agent email>
   ```
5. **Invite it to each repo**: run `team-bootstrap-repo <owner>/<repo> --apply` (it invites the agent as a collaborator). On personal repos GitHub always grants collaborators write access; you can't pick a lower role. Accept each invitation as the agent: open the invitation link while signed in as the agent, or run `GH_TOKEN="$(gh auth token -u <you>-agent)" gh api /user/repository_invitations` and `… gh api -X PATCH /user/repository_invitations/<id>` in a normal terminal.

## What changes in the pack

- `team-gh` and `team-post-check` act as the agent login. The one exception: `team-gh pr edit <n> --add-label owner-approved` (your yes moment) always runs as you.
- `team-new-worktree` sets the worktree's commit identity (`user.name`, `user.email`) and push URL (`git@github.com-agent:<owner>/<repo>.git`) from the agent line, using per-worktree git config. Worktrees created before you added the agent keep acting as you; recreate them.
- `team-bootstrap-repo` invites the agent; `team-verify-repo` reports a pending invitation.

## Turning it off

Delete the `agent|…` line from `accounts.conf`, remove the agent as a collaborator from each repo, and recreate open worktrees.
