# 0015 — Publishing a release from Relvora

- **Status:** Accepted (0.1.1; the owner asked for it). Replaces safety rule 1 in PRODUCT_SPEC §4 ("Never publish a release from the app") and amends [ADR 0010](0010-release-workflow-and-reconciliation.md).
- **Date:** 2026-10-23

## Context

Until now, Relvora only created drafts, and the owner had to open GitHub to publish each one. The owner asked to approve the release in the app too.

Publishing is the most consequential GitHub write:
- GitHub creates the tag.
- The release becomes visible to everyone who can see the repository.
- Workflows on `release: published` start; for Relvora's own repository, that is the signed build.

Publishing through the GitHub App's user token is attributed to the user, so it starts those workflows like a publish on github.com.

## Decisions

1. **Draft first, still.** Publishing is a second, separate step on a created draft (**Publish Release…**). There is no "create and publish", and nothing is published automatically.
2. **The confirmation shows the draft as GitHub has it now**, not as Relvora created it:
   - repository, tag, full target commit, title, and pre-release;
   - the notes, flagged when they were edited on GitHub;
   - whether GitHub will create the tag or use an existing one at the same commit.
   - The **Publish Release** button is never the Return key.
3. **Publishing is refused, before anything is sent, when the draft no longer matches what was reviewed** (`PublishProblem`):
   - its tag or target was changed on GitHub;
   - the tag exists at another commit (publishing would attach the release there, and Relvora never moves tags);
   - another published release already has the tag.
   - The fix is on GitHub: change the draft back, or delete it, choose **Check Publication**, and create a new draft.
4. **What was confirmed is what is published.** Just before sending, the workflow reads GitHub again. If anything in the draft changed since the confirmation, it throws `reviewOutdated` and the user confirms again.
   - If the draft was published or deleted on GitHub meanwhile, that is recorded instead, and nothing is sent.
5. **One request, no intent record.**
   - The request is `PATCH /releases/{id}` with only `{"draft": false}`, sent once.
   - It is idempotent: publishing a published release changes nothing and can't create a second release. So unlike the draft's create, no intent is saved first.
   - **Lost response:** the plan stays **Draft created**, and **Check Publication**, or **Publish** again, reads GitHub and records the publication.
   - **Rejected:** the draft is unchanged.
6. **Publication is verified as before** (ADR 0010 §6). The tag must point at the reviewed commit. Relvora waits up to two seconds for GitHub's new tag to be readable.
   - A mismatch goes to **Needs reconciliation**, as for a release published on GitHub.

## Consequences

- PRODUCT_SPEC §4 rule 1 now reads: a release is published only from a created draft, after the user confirms it as GitHub has it.
- Rule 2 is unchanged: Relvora never moves or deletes a tag. GitHub creates the tag on publication, at the reviewed commit, and a draft whose tag exists elsewhere is never published.
- The GitHub App needs no new permission: publishing uses the same *Contents: write* as creating drafts.
- Publishing on github.com still works, and **Check Publication** records it as before.

## Evidence

- `PublishWorkflowTests`:
  - a verified publish;
  - each blocking problem, with nothing sent;
  - a draft edited after the confirmation;
  - a lost response and a request that never arrived;
  - a rejection;
  - a draft published or deleted on GitHub meanwhile.
- `ReleaseAPITests`: the request sends only `draft: false` and is sent once.
- UI test `testPublishTheDraftFromRelvora`, against the in-memory demo GitHub.
