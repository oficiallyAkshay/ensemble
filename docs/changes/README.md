# Change notes

Each pull request adds one new file in this folder. The file holds one plain sentence: the release note for that change.

- Name the file for the branch, for example `faster-pinch-detection.md`. The pull request number is not known until it is opened.
- Write plain words about what the app now does. No ticket numbers and no private names: this folder is public.
- A pull request never edits `docs/CHANGELOG.md`. Because every pull request adds its own file, two open pull requests never change the same file and never conflict.
- At release time `scripts/release-notes.sh` prints one line for each note file added since the previous tag. A change with no note file is listed by its commit subject, so no change is lost.
