# breakZero 0.9.0 beta — notes for testers

breakZero opens Instagram, YouTube and Snapchat in calmer, filtered views inside one app, and keeps
the rules you set in a "Wall": making them stricter is instant, loosening them waits a cooldown.

## Getting started
1. Open the app: a short welcome explains the layout. Sign in inside each tab (your login goes to the
   site itself; breakZero never sees your password).
2. The button at the top right shows the tab bar: switch apps or open the **Wall**.
3. Instagram's feed shows **Everyone I follow** on the Following feed, with suggestions and ads
   hidden. To filter by who you follow, import your follow lists: Wall › Instagram › Feed rules ›
   *Import Instagram data* (HTML or JSON both work; choose Date range: **All time**).
4. Something wrong? Wall › **Send feedback** (an email with the app version, iOS version and phone
   model; nothing else is attached). The version is at the bottom of the Wall.

## What's new in this build
- The home feed no longer churns: only approved posts are shown in a steady list; loading skeletons,
  suggestion rows and spinners are never shown; nothing flashes below "You're all caught up".
- Leaving a story (close, swipe down, the last story ending, back) returns you to where you opened it
  — feed, profile or DM thread — instead of Messages.
- The Hide button on posts has its own row and never covers Instagram's Follow button.
- Instagram's default HTML export imports (followers, following). If it covers less than all time,
  you're told which dates are missing.

## Known issues
- **Experimental rules.** *Mutuals only*, *My list* and *Close Friends* hide most of the feed, so
  Instagram keeps loading more and you may see few posts, or "You're all caught up" quickly.
  *Everyone I follow* is the steady choice for this beta.
- **Stories tray on the plain Home feed.** There the tray circles aren't links, so a circle of
  someone outside your rules can show. Their story never plays: it skips to the next allowed person
  or closes back to where you were. (The Following feed has no tray on mobile web.)
- **A skipped story loads as a new page**, so there's a brief loading moment. Coming back afterwards
  returns to your feed entry; if iOS had to reload the feed, the scroll position is restored as
  closely as Instagram's reloaded feed allows.
- **Close Friends** can't come from the HTML export (Instagram's file has no profile links). Use
  Feed rules › *Import Close Friends* instead (it reads the checked names on Instagram's own list).
- **iOS can reload a tab** when it's low on memory; breakZero reopens the same page.
- **Instagram can change its page at any time.** If it does, posts stay hidden rather than slipping
  through, and Diagnostics (tap the version at the bottom of the Wall five times) can report what
  changed.
- **This version can't stop the real apps.** It only filters inside breakZero; deleting breakZero
  removes the Lock. (The Screen Time version needs a paid developer account.)
- **Free developer signing**: a build installed from Xcode with a free account stops opening after 7
  days; reinstall to continue.
