# Great Graphs

A daily question for a friend group. Each day everyone either draws a curve (energy through the day, how drunk after each drink…) or ranks a list (numbers 1–10 by vibes, pizza toppings…). Once you've answered, you see your group's answers combined: everyone's curves, the group average, stats like most agreed and most divisive, and some jokes.

## How it works

- **Profiles:** pick a username once. You get a personal code to sign in on another device.
- **Groups:** permanent rooms. Whoever creates a group is its host and adds friends by username. You can be in several groups.
- **No peeking:** the database only returns a group's answers to people who've answered that question themselves.

## Files

- `index.html`: the whole app (no build step).
- `config.js`: your Supabase project URL and anon key.
- `supabase/setup.sql`: run once in Supabase's SQL Editor to create the tables and functions.

## Setup

1. Create a Supabase project, open **SQL Editor**, paste in `supabase/setup.sql` and press **Run**.
2. Put the project URL and anon (publishable) key into `config.js`. The anon key is meant to be public; the tables are locked and only the functions in `setup.sql` can be called.
3. In GitHub: **Settings → Pages → Deploy from a branch → `main` / root**. The site appears at `https://<user>.github.io/groupgraphs/`.

## Adding questions

Questions live in the `CURVES` and `RANKS` arrays near the top of the script in `index.html`. The daily question rotates through them in order.
