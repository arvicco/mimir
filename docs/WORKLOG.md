# Worklog

One line per completed packet: date · packet · commit · notes.

---

2026-07-03 · M0-2 (draft) · -- · docs/TOOL-REVIEW.md: full read of all 22 scripts (~3k lines); 15 findings incl. one confirmed latent bug (btco convert FX math, rate^2 understatement), fit.rb ungated history write, btco fail-soft mismatch, 5x HTTP helper duplication; Phase 1 refactor list proposed. Awaiting owner review.
2026-07-03 · M0-1 · -- · Loop bootstrap on phase-0: .claude/settings.json permission profile (repo-sandbox allow, hard deny on wrangler/fixtures:record/main-push/secrets), GitHub Actions CI (compat+test, ubuntu + macos-arm64, Ruby 3.3), backlog with elaborated Phase 0 packets, this worklog. Push policy decided: loop pushes phase-N + opens PRs, main owner-merged.
