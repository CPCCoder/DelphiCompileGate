## Summary

Describe the problem and the implemented change.

## Validation

List the automated and manual checks performed. Explain any checks that were not
run.

## Checklist

- [ ] The change is focused and contains no generated binaries, caches, runtime
      queue data, credentials, or private compile evidence.
- [ ] Tests cover changed behavior where practical.
- [ ] `python -m pytest` passes.
- [ ] Python sources pass `py_compile`.
- [ ] `git diff --check` passes and tests leave tracked files unchanged.
- [ ] Documentation and `CHANGELOG.md` are updated when applicable.
- [ ] Protocol, schema, version, and release implications are identified.
- [ ] Security-sensitive details use the private reporting process in
      `SECURITY.md` rather than this pull request.
