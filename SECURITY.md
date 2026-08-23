# Security

This document covers the repository-specific security expectations for Aura Browser contributors and maintainers.

## Secrets and Sensitive Data

- Never commit `.env`, signing credentials, private keys, notarization credentials, or any other secret material.
- Do not paste secrets into issues, pull requests, screenshots, or logs shared publicly.
- Keep local release credentials in `.env` and use `.env.example` as the template for required variables.
- Treat generated logs and exported artifacts as potentially sensitive until reviewed.

## Update Signing

Aura uses Sparkle update signing.

- `aura_public_key.pem` is the public verification key and is safe to keep in the repository. The same value ships in the app as `SUPublicEDKey`.
- The matching EdDSA private key lives in the login keychain, where Sparkle's `generate_keys` puts it. Never commit it, export it into the repository, or share it.
- If the private signing key is lost or replaced after releases have shipped, the existing update trust chain is broken.

## Release Credentials

`./scripts/release.sh` is the current release flow. It needs `gh` logged in, an Apple Development signing identity, and the Sparkle EdDSA key in the login keychain. None of those belong in the repository.

`.env.example` lists the variables a notarized build needs on top of that:

- `APPLE_ID`
- `TEAM_ID`
- `DEVELOPMENT_TEAM`
- `APP_SPECIFIC_PASSWORD_KEYCHAIN`
- `SIGNING_IDENTITY`
- `DEVELOPER_ID_PROFILE`

Keep real values in a local `.env`, which is git-ignored.

Contributors working on regular code or documentation changes should not need access to release credentials.

## Safe Working Practices

- Review `git status` and `git diff --cached` before every commit.
- Do not add private keys, provisioning profiles, or notarization credentials to the repository, even temporarily.
- Be careful when sharing crash logs, build logs, and environment output if they may include local paths, account identifiers, or signing details.
- Follow least-privilege access for Apple Developer and release infrastructure credentials.

## Reporting Security Issues

If you discover a security issue or accidental secret exposure, do not open a public issue with exploit details or credential contents. Open a private security advisory at https://github.com/Sowyu/Aura/security/advisories/new so the issue can be handled without further exposure.
