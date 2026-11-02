# Security

If you find a security problem in SimplMaker, please report it privately and not in a public issue.

- Use GitHub's private vulnerability reporting: **Security → Report a vulnerability** on this repository, or
- write to support@simplmaker.com.

SimplMaker is a desktop app that works offline. The places where it talks to the network are the update check (Sparkle, over
HTTPS, with signed archives), anonymous usage statistics in the official builds, and an optional local server for AI assistants
(off by default, bound to this Mac, protected by a secret token). Reports about any of them are welcome, as are reports about files that crash
or hang the app when opened.

Only the latest release is supported with fixes.
