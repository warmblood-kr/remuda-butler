# Issue text: Matrix receive rules, low findings from the security review of #178

Title: Matrix receive rules: four low findings from the security review of #178

The security review of #178 (at 0b6831a) found four low items. None blocks the PR. The two medium items were fixed in the PR.

- **L1. `matrix.trusted` is not stored with the mail.** It is only in the `butler/deliver` hook payload. `mail.lua` `envelope_json` does not store it, so a stored mail (`inbox --json`, or after a restart) has only the body marker. Either store it or remove the promise from `docs/butler.md`. Storing it would also let the mail notice leave the sender out for a non-allowlisted sender.
- **L2. The control and bidi strip assumes valid UTF-8.** It is a single-pass `gsub`; with broken byte sequences a removal can join bytes into U+202E. This is fine only if `json.decode` always gives valid UTF-8: confirm it, or strip until nothing changes. Invisible tag characters (the U+E0000 block) and zero-width characters are not stripped.
- **L3. The rate cap is per room and in memory.** One non-allowlisted sender can use the 20 slots; other non-allowlisted senders in that room are then dropped without quarantine for the hour, and a relay restart resets the count. This is by design in the smallest cut: say so in `docs/butler.md`, and revisit with PR 2.
- **L4 (existed before #178). `relation_fields` takes `event_id` of any JSON type.** A non-string value reaches `pending.thread_root`. Accept only a string.

Related: #173 (follows in their own file), #174 (misspelled verb).
