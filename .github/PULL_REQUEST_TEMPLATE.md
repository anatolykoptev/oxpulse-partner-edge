## Summary

<!-- 1-3 sentences: what changes and why -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Build / CI / tooling
- [ ] Security fix
- [ ] Breaking change

## Evidence

<!--
How do you know this works? Be specific and be honest about the limits.

  - Test that fails without the patch and passes with it — name it.
  - For anything that runs on a host (metric, unit, timer, endpoint, flag):
    output from a real probe, or a plain sentence saying you could not run
    one. "Untested on a live edge" is an acceptable answer here; silence
    is not.
-->

## Checklist

- [ ] I have read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] I have signed (or will sign) the [CLA](../CLA.md) — required for all contributions
- [ ] **Every behaviour named in my commit message and PR description is present in this diff**
- [ ] I used `Fixes`/`Closes` only if this diff removes the cause — otherwise `Refs`
- [ ] No test fixture or assertion was weakened to make CI pass
- [ ] CI passes locally (`make lint`, `cargo test`, shell checks)
- [ ] If user-facing: docs / README / CHANGELOG updated
- [ ] If security-sensitive: notes in PR body explaining threat model impact

## Related issues / PRs

<!--
`Closes #N` auto-closes the issue on merge — use it only when the cause is
gone. Otherwise `Refs #N` and say what is left.
-->
