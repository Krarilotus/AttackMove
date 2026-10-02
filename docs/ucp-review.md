# UCP integration review

Attack Move now has a short description and readable settings in every UCP launcher language. Waypoint fixes and optional Alt movement appear in their established categories.

Adds all nine launcher locales, declared UCP dependencies, schema metadata, defaults and a runtime allowlist. Moves detailed explanations to the README. Existing movement behavior and option values are preserved.

## Remaining native work

Native click/modifier ownership must compose with Custom Hotkeys, the cursor and command owners. The private LAST command cache influences queued routes and needs save/load/replay boundary validation; its unit UID guard alone is not that validation. The waypoint correction may join Fixes after acceptance; Alt stacking remains a separate optional capability.

Inspected upstream parent: `410808f1142bc3424abf7879cc8b2bb3c6fc1ac9`. Launcher locales follow
`UCP3-GUI/resources/lang/languages.yaml` (de, en, fr, ru, hu, tr, ch, es, fa).
Category identities follow the current Legacy/GUI catalog, including its existing
English category fallback; setting and description text has full locale entries.
Human translation review and installed GUI/RTL layout checks are pending.

Offline checks passed: YAML/default consistency, actual GUI control types,
all referenced locale keys, Lua 5.4 syntax and runtime package inputs. Runtime
allowlists exclude research/bench Python. These are not game/editor/save/replay
acceptance. Multiplayer testing belongs to players. No Store release is claimed.
