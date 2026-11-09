# GroupGraphs

A daily question for a friend group. Each day everyone draws a curve (energy through the day, how drunk after each drink…), ranks a list (numbers 1–10 by vibes, pizza toppings…), or drops themselves on a 2D map (chaos vs order, night owl vs early bird…). Once you've answered, you see your group's answers combined: everyone's curves, the group average, stats like most agreed and most divisive, and some jokes.

## How it works

- **Profiles:** pick a username once. You get a personal code to sign in on another device.
- **Groups:** permanent rooms. Whoever creates a group is its host and adds friends by username. You can be in several groups.
- **No peeking:** the database only returns a group's answers to people who've answered that question themselves.
- **Group chat:** each question has a chat that only your group sees. Post a comment, or add a "rule" (a further constraint like "assume you slept 8 hours") that's pinned above the question.
- **Your color:** under Groups & profile, pick any color on the color wheel or type a hex code, and you're that color on every chart.
- **Group streak and nudges:** today's question shows how many days in a row everyone in the group has answered, who's answered today, and a Nudge button next to anyone who hasn't. A nudge can carry a short message; it shows up in the app and as a notification if they turned those on.
- **Results are in:** when the last person in a group answers today's question, everyone else gets a notification.
- **Your stats:** a personal page with your streak, best match, how often you're the odd one out, and your hottest takes.
- **Feedback:** members send bugs and ideas from the Feedback box. It all goes to the app owner's inbox (the host of the oldest group when `feedback.sql` is run; change it with `update gg_settings set v = 'username' where k = 'owner';`).
- **Daily reminder:** under 🔔 Reminder, pick an hour and turn on phone notifications (iPhone: add the site to your Home Screen first), or add a repeating event to Apple/Outlook/Google Calendar. Notifications skip days you've already answered.

## Files

- `index.html`: the whole app (no build step).
- `config.js`: your Supabase project URL and anon key.
- `supabase/setup.sql`: run once in Supabase's SQL Editor to create the tables and functions.
- `supabase/comments.sql`, `supabase/reminders.sql`, `supabase/summary.sql`, `supabase/ideas.sql`, `supabase/feedback.sql`, `supabase/groups-extra.sql`, `supabase/social.sql`, `supabase/results-alert.sql`: the same additions on their own, for a database set up before they existed.
- `keys.html`: one-time page that makes the notification key pair in your browser.
- `sw.js`, `manifest.webmanifest`, icons: let the site install to a home screen and receive notifications.
- `scripts/send-reminders.mjs` + `.github/workflows/reminders.yml`: a GitHub Action that runs every 10 minutes and sends the reminders and nudges.

## Setup

1. Create a Supabase project, open **SQL Editor**, paste in `supabase/setup.sql` and press **Run**.
2. Put the project URL and anon (publishable) key into `config.js`. The anon key is meant to be public; the tables are locked and only the functions in `setup.sql` can be called.
3. In GitHub: **Settings → Pages → Deploy from a branch → `main` / root**. The site appears at `https://<user>.github.io/groupgraphs/`.
4. For notifications (optional): open `keys.html` on the live site, save the private key it shows as the GitHub Actions secret `VAPID_PRIVATE_KEY`, and run the SQL it shows in Supabase. The hourly workflow does the rest.

## Adding questions

Questions live in the `CURVES`, `RANKS`, `MAPS` and `SCI` (lab) arrays near the top of the script in `index.html`. Lab questions come up every third day. Players only ever see one question a day (today's, plus earlier days via the back arrow); the rotation goes through the bank in order starting Nov 3, 2026, and the new question appears at midnight Central time for everyone (Nov 5 is the drinks question, Nov 6 numbers by vibes).
