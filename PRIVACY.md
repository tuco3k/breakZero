# Privacy

breakZero collects nothing. There is no account, no server, no analytics, no crash SDK, no ads.

## Network traffic
breakZero itself talks to exactly two kinds of places, enforced in code by a single `NetworkPolicy`
type and a test that fails if any other file uses networking APIs:

1. **The sites you open** (instagram.com, youtube.com and their login pages) inside the lite views.
   That traffic is between you and those sites, just like in Safari.
2. **Optional filter updates** (off by default): one static file URL on GitHub Pages, fetched with no
   cookies, no cache and no identifiers. Updates are signed data, never code.

Links that leave a platform open in Safari's in-app browser, which is Safari's traffic, not ours.

## What stays on your phone
Your wall settings, the pending-change queue, your native-pass log (with the purposes you typed),
your feed rules and lists, who follows you and whom you follow (from your own Instagram data
export, or read from your own lists on screen), the accounts hidden recently (memory only), and a
diagnostics log (counts only for those, never names). Your data export is read on the phone and
never uploaded. Nothing read from a page ever leaves the device. The *Report* button on a
"Filter needs an update" banner opens a prefilled GitHub issue in Safari containing only the
platform, recipe version, the failed check's id, and app/iOS versions — you choose whether to send it.

## App Store privacy label
Data Not Collected.
