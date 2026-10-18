# Deep-link findings — Acer R4 (Android TV 14), 2026-10-18

Sent with `RemoteSession.launch(appLink:)` (RemoteAppLinkLaunchRequest, field 90). The TV's
remote service fires `ACTION_VIEW` on the URI; whichever app's intent filter claims it opens.
"Claims" = `cmd package query-activities -a VIEW -c BROWSABLE -d <url>` on the TV.

| App (package) | URL form that works | Result | Gotchas |
|---|---|---|---|
| Netflix (`com.netflix.ninja`) | `https://www.netflix.com/title/<id>` (also `/watch/<id>`, `nflx://`) | Opens Netflix; the title page autoplays its preview. | FLAG_SECURE, so screenshots are blocked and the title wasn't confirmed visually. **Needs a human glance.** |
| Prime Video (`com.amazon.amazonvideo.livingroom`) | `https://app.primevideo.com/detail?gti=amzn1.dv.gti.<uuid>` | ✅ **The Family Man** detail page | `www.primevideo.com/detail/...` is **not** claimed and falls to a browser stub. A cold start shows the profile picker first, then the deep link continues after OK. |
| JioHotstar (`in.startv.hotstar`) | `https://www.hotstar.com/...` (also `hotstar://`) | `/in/shows/aarya/1260028094` → **ERR_PB_1410** screen. Without `/in/`, it opened a secure screen I couldn't inspect. | `www.jiohotstar.com` is **not** claimed (the web 301s to hotstar.com anyway). IDs are numeric and the slug is ignored. **Needs a human glance.** |
| YouTube (`com.google.android.youtube.tv`) | `https://www.youtube.com/watch?v=<id>` | ✅ Opens the video player | — |
| SonyLIV (`com.sonyliv`) | `https://www.sonyliv.com/shows/<slug>-<id>` (also `sonyliv://`) | ✅ **Scam 1992** detail page | Goes Splash → Home → detail, about 10s. |
| Apple TV (`com.apple.atve.androidtv.appletv`) | `https://tv.apple.com/in/show/<slug>/umc.cmc.<id>` | ✅ **Ted Lasso** detail page | Shows a "Who's Watching?" picker first; the deep link continues after OK. |
| F1 TV (`com.formulaone.production`) | none | ❌ Declares no VIEW intent filters, so it can't be deep-linked. `market://launch?id=…` is unresolved on this TV (Play Store is enabled but doesn't claim it, `result -91`). `intent:#Intent;…component=…;end` is rejected by the remote service. | Can't even be *opened* over the remote protocol. Options: ADB `am start`, or put it on the custom launcher and navigate with the D-pad. |

## Implications for cross-app search (next phase)
- Prime: needs `app.primevideo.com/detail?gti=` links. JustWatch already returns this form (see below), so no GTI mapping is needed.
- JioHotstar: use `www.hotstar.com` links, never `jiohotstar.com`. Behaviour still needs checking by eye.
- Profile pickers (Prime, Apple TV) interrupt but don't lose the link. The app could send OK about 6s after launching.
- F1 TV is out unless we use ADB.

## Search source: JustWatch (2026-10-18)
`apis.justwatch.com/graphql` `popularTitles(country: IN)` → `offers.standardWebURL` gives TV-openable
links for every installed app. Prime already comes as `app.primevideo.com/detail?gti=…`, Hotstar as
`www.hotstar.com/in/<id>`, SonyLIV and Apple TV as episode URLs. All land on the title's page;
Hotstar is not visually confirmed because its screen is secure. JustWatch's `deeplinkURL(platform:
ANDROID_TV)` returns `intent://…` URIs, which the remote service rejects, so the widget filters
offers by URL host instead.
