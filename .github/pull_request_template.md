## 📝 Description

<!-- Describe your changes here -->

## Release highlights

<!--
Optional. For a milestone, two or three sentences on what it means for someone using Malachi: they open the
release notes, above the grouped list of changes. Leave this section empty otherwise; comments like this one
are dropped. Only a pull request whose author has write access to the repository contributes highlights.
-->

## 🔖 Type of Change

<!--
The title decides it, in Conventional Commits form (type(scope)!: summary); see the note at the end.
Mark with [x] what the title says.
-->

- [ ] 🐛 **Patch** - fix, perf, revert, or a dependency or base image update (increments 0.0.X)
- [ ] ✨ **Minor** - feat (increments 0.X.0)
- [ ] 💥 **Major** - breaking change, `!` in the title or the `major` label (increments X.0.0)
- [ ] 📄 **No release** - docs, chore, ci, test, refactor, style or build (listed in the next release)

## ✅ Checklist

- [ ] Code follows project style guide
- [ ] Comments added to complex code
- [ ] Documentation updated
- [ ] Tests added/updated
- [ ] All tests passing
- [ ] Changes don't break existing functionality

## 🧪 How to Test

<!-- Describe how to test your changes -->

## 📸 Screenshots (if applicable)

<!-- Add screenshots if there are visual changes -->

## 🔗 Related Issues

<!-- Ex: Closes #123 -->

---

**Note about versioning:**
- The merged title decides the release: `feat` a minor, `fix`, `perf`, `revert`, `chore(deps)` and `chore(docker)` a patch, `!` after the type (`feat!:`) a major
- docs, chore, ci, test, refactor, style and build publish no release; they appear in the next one's notes
- The `major` label forces a major; the `release` label releases a patch for a type that would publish none
- See the [Versioning section in the README](https://github.com/malachi-hq/malachi#-versioning) for details
