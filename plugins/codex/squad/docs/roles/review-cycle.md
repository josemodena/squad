# The review cycle

Every piece goes through the same cycle, from plan to merge. The Engineer, the
Engineering Reviewer and the Project Manager each own part of it.

## The plan

A piece is an issue whose body is its plan, written from the piece template
under three headings, in this order:

- **Why**, in plain words: the reason for the piece, what goes wrong or stays
  missing if it is not done, and the goal or milestone it brings closer.
- **What**: what the piece produces, what it leaves out and what it depends on.
- **How**: the approach, and the acceptance test, written before the work starts.

`squad.sh issue` writes this body when no other is given. A follow-up issue,
whether scope found mid-piece, a note from a review or a finding from a cold
run, carries all three headings too.

## The rules

1. **Machine gates before any Reviewer.** The affected tests, the linters and the
   product checks pass before the pull request opens. A documents piece runs
   its link and content checks instead. No Reviewer starts on a pull request
   whose gates have not passed.
2. **Small pull requests.** About 400 non-test lines at most. A bigger piece is
   split in dependency order, and each part stands on its own tests.
3. **One review**, scoped to the diff and the acceptance criteria. The Reviewer
   merges the head onto current main where nothing can be pushed, runs the
   affected checks and classes every finding **blocking** or **note**.
4. **Notes do not block.** They become follow-up issues or are dropped.
5. **A named fix is checked by the merger.** Blocking findings go to a fresh
   Engineer, who changes only those findings. The merger reads the fix's diff
   and runs the affected checks before merging. There is no second review unless
   the fix changes behaviour beyond the findings.
6. **Fixtures are never written by the Engineer.** The Architect or the Reviewer
   chooses them. A piece that passes only on a fixture of its own is refused.
7. **Two full test suites at once, at most**, on one machine.
8. **One cold run mid-sprint**: one end-to-end run from a clean start, not one
   per piece. What it finds is filed as follow-up issues.

## The verdict

The Reviewer's report is a comment on the pull request. Its verdict line starts
with `Verdict:` and uses one of three exact forms, followed by the full reviewed
head before any other commit hash:

```text
Verdict: merge. Reviewed head <40-character sha>.
Verdict: merge after named fixes. Reviewed head <40-character sha>.
Verdict: do not merge. Reviewed head <40-character sha>.
```

On a pass, the comment also carries the marker line that `gitw.sh finish` checks:

```text
<!-- squad-review-passed:<40-character sha> -->
```

`squad.sh review-record PR --head SHA --verdict pass|fixes-required|do-not-merge`
writes both lines in this form. `squad.sh merge` reads only a line starting
`Verdict:`; any other wording is refused.

## The merge

`squad.sh merge PR ISSUE` merges a head the Reviewer passed. After named fixes
the head has moved: the merger first checks the fix's diff, then posts a comment
naming the new head, and `merge` accepts it when the fix commits follow the
reviewed head. Once GitHub has merged, `merge` finishes the close-out even when
one step fails, such as a card move, and lists what failed at the end.
