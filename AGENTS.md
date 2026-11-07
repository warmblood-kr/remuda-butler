# Working in this repository

Butler is a Remuda mod. The guidance Butler gives delegated members is
generated at launch from `packages/butler/agents_launch.lua` and
`packages/butler/init.lua`; edit those sources rather than a generated
`AGENTS.md` in a member's directory.

## Milestones

At the start of a task, set a self-targeted milestone reminder:

```
remuda butler schedule add milestone "<M> <H> * * *" \
  "Milestone: re-check the task and its definition of done, re-check the approach, align the team; set the next --once reminder if the work continues; report only new evidence, a decision, a change or a blocker" --once
```

Use 20-30 minutes for fast work and one hour for normal work. When it fires,
remind yourself of the task and its definition of done, re-check whether the
current approach is still the shortest safe path, confirm your members are
aligned, and set the next reminder if the work continues. The reminder is for
that self-check, not a duty to report to a human every time; if a risky path
goes beyond your remit, use your judgment and escalate to your leader or the
team. Report to your leader or the owner when you have new evidence, a decision,
a change, or a specific blocker; never send repetitive empty reports.
