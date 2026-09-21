# Which template goes where

Three near-identical templates, three different destinations. Sending the wrong
one to the bug tracker makes the BTS **silently ignore** the whole message,
because it parses the first lines of the body as pseudo-headers.

| File | To | First line of the body | Purpose |
| --- | --- | --- | --- |
| `itp-bug.txt` | `submit@bugs.debian.org` | `Package: wnpp` | Intent To Package (already filed: #1148567) |
| `rfs-bug.txt` | `submit@bugs.debian.org` | `Package: sponsorship-requests` | Request For Sponsorship |
| `mentors-list.txt` | `debian-mentors@lists.debian.org` | `Hi,` | Plain mail to the mentors list |

Rules that follow from that:

* For the two bug templates, **nothing may come before the `Package:` line** —
  not a greeting, not a signature, not a quoted header block. A mail client that
  prefixes the body (or an HTML compose mode) breaks the submission.
* `mentors-list.txt` is *only* for the mailing list. The BTS rejects it:
  "Your message didn't have a Package: line at the very first line of the mail
  body (part of the pseudo-header)".
* Fill in the placeholders (`RFS_BUG`) before sending, or the mail points at a
  page that does not exist.
* Keep `debian/changelog`, `rfs-bug.txt` and `mentors-list.txt` on the same
  version — the version in the RFS must match what mentors is actually hosting,
  or the `dget -x` line 404s for the sponsor.
