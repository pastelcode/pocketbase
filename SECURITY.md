# Security Policy

## Supported versions

This package is pre-1.0. Security fixes are provided for the latest released version only; older releases should be upgraded.

| Version | Supported |
| ------- | --------- |
| Latest `0.x` release | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them privately through GitHub's [private vulnerability reporting](https://github.com/pastelcode/pocketbase/security/advisories/new) (Security tab → *Report a vulnerability*).

Include as much of the following as possible:

- The affected version (or commit) and platform(s).
- A description of the issue and its security impact.
- A minimal reproduction or proof of concept.
- Any suggested fix or mitigation, if you have one.

## What to expect

- **Acknowledgment** within 72 hours.
- An initial assessment (severity, affected versions, fix plan) within 7 days.
- A fix released as soon as practical, credited to you in the release notes unless you prefer to stay anonymous.
- Coordinated disclosure: please give us a reasonable window to release a fix before publishing details.

This project has no bug bounty program.

## Scope

In scope:

- The SDK itself: the request/transport pipeline, auth stores, cookies, JWT handling, realtime transport, batch serialization and the other services.
- Supply-chain concerns in this repository, such as the CI workflows and the release process.

Out of scope:

- The PocketBase server and dashboard — report those at [pocketbase/pocketbase](https://github.com/pocketbase/pocketbase/security).
- Vulnerabilities in third-party dependencies (report them upstream; Dependabot tracks updates here).
- Issues caused by misconfiguration of an application or server, and social-engineering attacks.

## Safe harbor

We consider security research conducted in good faith — on your own test environment, without accessing other users' data, and with responsible disclosure — to be authorized. We will not pursue legal action for such research.
