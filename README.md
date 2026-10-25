# Issue Island

A small macOS app that turns the MacBook notch into a Dynamic Island-style pill and watches one GitHub
repository's open issues. When a new issue is opened, the island expands with a sound, the little character in
the pill reacts, and a macOS notification appears. Click to read the issue, open it on GitHub, or copy a request
to plan the fix in Claude Code.

- Open issues grouped as assigned to you, unassigned, and assigned to others, with GitHub label colors.
- Ten original characters to choose from, with eyes that follow the pointer.
- Check interval from 15 seconds to 1 hour, and an option to start at login.
- Signs in through the GitHub CLI (`gh`), so the app never stores a token.
- Light on battery: the character only animates smoothly while you're near the notch.

## Requirements

- macOS 14 or later on Apple silicon.
- [GitHub CLI](https://cli.github.com) (`gh`). The app offers to install it with Homebrew if it's missing.
- Xcode Command Line Tools, to build from source.

## Build and run

```sh
./build.sh
open "$HOME/Applications/Issue Island.app"
```

The build script compiles `main.swift` into `~/Applications/Issue Island.app`. On first launch, open Settings in
the island, sign in with GitHub, and pick a repository to watch.

`./build.sh --zip` also packs the app into `dist/Issue Island.zip` to share. The app is ad-hoc signed, not
notarized, so whoever opens it must allow it once in System Settings → Privacy & Security → Open Anyway.

## License

Issue Island is open source under the [MIT License](LICENSE). You're free to use, copy, modify, merge, publish,
distribute, sublicense, and sell copies, including in commercial projects, as long as the copyright notice and
license text are kept with the software. It comes with no warranty.

Contributions are welcome. Unless you say otherwise, anything you submit is licensed under the same MIT terms.

The characters are original drawings made in code and are covered by the same license. This project is not
affiliated with or endorsed by GitHub. "GitHub" is a trademark of GitHub, Inc.
