# Features

What's in Reel Manager, by milestone.

## Milestone 1: safe publishing (version 0.3.0)

- **Approval first.** Every post is a draft until you approve it. "Approve & Post" and "Approve & Schedule" in Compose count as approval; "Save as Draft" doesn't. Only approved posts can be scheduled or published. Editing an approved post's caption, text or privacy sends it back to draft.
- **Post states:** Draft, Approved, Scheduled, Publishing, Published, Failed, Cancelled, Held. Times are stored in UTC and shown in your time zone.
- **Rules** (Settings › Publishing):
  - posts per account per day, posts in total per day, and per-platform pauses
  - minimum gap between posts on one account
  - an optional posting window, and quiet hours
- **Held, not dropped.** When a rule blocks a post that's due, it's marked Held with the reason and checked again when the rule allows.
- **Kill switch:** "Pause All Publishing" in the menu bar, the Accounts menu (⇧⌘.) and Settings. You can also pause single accounts and whole platforms.
- **Waits when the Mac isn't ready:** low battery (not charging), offline, or low disk space.
- **Failure breaker:** an account is paused after 3 failures in a row (you can change the number). An account whose sign-in can't be renewed is paused too. The only way back in is the platform's own login.
- **No double posts.** Each publish saves its progress after every step. After a crash or quit, the retry first asks the platform what happened (Instagram container status, Facebook video status, TikTok publish status, YouTube upload session). Only if nothing was published does it upload again. A database claim stops the app and the background publisher from sending the same post at once.
- **Background publisher** (Settings › Publishing). It's a launch agent that starts at login, restarts after a crash, and keeps posting approved posts when the app is closed. It never wakes a sleeping Mac. You get a warning when you schedule a post between 1 and 6 am.
- **Notifications:**
  - immediately, for every post, failure and pause
  - a morning digest at 8 am
  - a warning when the queue is about to run out
  - a warning when a sign-in is about to expire
- **Activity log:** every attempt, approval, schedule, hold and pause, kept for 90 days. Tokens and secrets are redacted before anything is written.

## Earlier

- Import, library, variation editor (crop, pan, zoom, rotate, color, cuts, speed, on-screen text), version history, comparison.
- Official OAuth sign-in for Instagram, Facebook Pages, TikTok and YouTube, with many accounts per platform.
- Compose: one box, with captions and on-screen text per account. Post now, schedule, or stagger.
- Retries with backoff, rate limiting, analytics, dashboard, setup wizard.

## Next

- Milestone 2: calendar and queue.
- Milestone 3: editor upgrades.
- Milestone 4: analytics and reports.
- Milestone 5: AI assistant (drafts only, always approved by you), security, accessibility.
