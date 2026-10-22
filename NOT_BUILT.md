# Not built, and why

Reel Manager follows each platform's rules and uses only their official APIs.
These features were asked for, or are close to something that was asked for,
and were left out on purpose. If a feature request conflicts with the rules
below, it goes on this list instead of into the app.

## Left out

| Feature | Why it isn't in the app |
|---|---|
| Uniqueness or similarity score ("X% similar, add more crop") | Its purpose is to get past duplicate-content detection. Instagram, Facebook, TikTok and YouTube all prohibit that, and accounts that do it can be banned. |
| Guides on which edits are "strong signals" for the algorithm | Same reason: the guidance exists to evade detection. |
| Auto-suggested edits to make variations harder to match | Same reason. |
| Matching variations to accounts so they look unrelated | It makes linked accounts look unlinked. |
| Stripping metadata, or changing file hashes or visual fingerprints, to avoid detection | Evasion. Removing location and device info from your own files for privacy is allowed and may be added as an export option. |
| Device, IP or browser fingerprint spoofing | Evasion. Not allowed. |
| Signing in with stored passwords, or automating the platforms' websites or apps | Only official OAuth sign-in is used. Passwords are never stored. |
| Scraping, or automated feed scrolling | Against every platform's terms. |
| Automatic follows, likes, comments, DMs or "warm-up" activity | Fake engagement. Not allowed. |
| Publishing anything you haven't approved | Every post needs your approval first. AI-written text will need approval too. |
| Hiding one account's activity from another account | It makes accounts look unlinked. |
| Buying followers, engagement or accounts | Not allowed. |

## Allowed, and planned or built

- Removing embedded location and device info from your own files before export (privacy).
- Duplicate-content warnings that are shown to you for review, never used to dodge detection.

## Platform rules the app relies on

These limits are built into the app's defaults and warnings. They come from
each platform's developer documentation. **None of them has been re-checked
against the current docs in this build**, and platforms change them often.
Please confirm them when you register your developer apps, and update
`lastVerified` when you do.

| Platform | Rule | Where the app uses it | lastVerified |
|---|---|---|---|
| Instagram | About 50 API-published posts per account per 24 hours. The app reads the live number from `content_publishing_limit` before every post. | InstagramClient | not verified |
| Instagram | Reels must be 3 seconds to 15 minutes. Professional (business or creator) accounts only. | PlatformSpec | not verified |
| Instagram | Until Meta approves the app, only tester accounts can sign in. | Setup guide | not verified |
| Facebook | Page Reels must be 3 to 90 seconds, 9:16. | PlatformSpec | not verified |
| TikTok | Until TikTok audits the app, posts can only be private (SELF_ONLY). The privacy level must be chosen for every post. | TikTokClient, Compose | not verified |
| TikTok | Uploads go in chunks of 5 to 64 MB. | TikTokClient.chunkPlan | not verified |
| YouTube | Until Google audits the project, uploads are locked to private. Each upload costs about 1,600 of the default 10,000 daily quota units. | YouTubeClient, Setup guide | not verified |
| YouTube | In "Testing" mode, refresh tokens expire after 7 days, so the account needs to log in again weekly. | Setup guide | not verified |

## Waiting for your go-ahead

The spec says to ask before building these:

- 37. Sponsorship tracking
- 38. Briefs
- 39. Importing from other tools
- 40. Data portability / export
